#!/usr/bin/env bash
# Bootstrap: build the merged snapshot when it is needed, and seed the merged
# stream if it doesn't exist yet. Run by the entrypoint once, then by
# supercronic at every tick. Most runs decide there is nothing to do and exit.
#
# Builds a snapshot when the stream isn't seeded, or when the database needs an
# import (no replicate_id for the current region list) and there is no usable
# snapshot (one for the current region list whose diffs S+1..head are all
# still in the stream).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
check_regions

head=$(merged_head)
rid=$(db_replicate_id)
kept=$(snapshot_seq)
usable=''
if is_seeded && [ -n "$kept" ]; then
  if ((kept == head)) || [ -f "$REPL/minute/$(seq_path $((kept + 1))).osc.gz" ]; then usable=1; fi
fi
if is_seeded && { [ -n "$rid" ] || [ -n "$usable" ]; }; then
  exit 0
fi

# From here on this is a real run: record it for status.txt and health.sh.
# A previous run still marked "running" was killed (e.g. OOM), so it failed.
fails=$(kv_get bootstrap.txt bootstrap_consecutive_failures)
fails=${fails:-0}
[ "$(kv_get bootstrap.txt bootstrap_result)" = running ] && fails=$((fails + 1))
kv_set bootstrap.txt bootstrap_consecutive_failures "$fails"
kv_set bootstrap.txt bootstrap_last_start "$(date -u +%FT%TZ)"
kv_set bootstrap.txt bootstrap_result running
RESULT=ok
on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    fails=0
  else
    RESULT=failed
    fails=$((fails + 1))
    log "bootstrap failed (exit $rc, $fails consecutive failures)"
  fi
  kv_set bootstrap.txt bootstrap_last_end "$(date -u +%FT%TZ)"
  kv_set bootstrap.txt bootstrap_result "$RESULT"
  kv_set bootstrap.txt bootstrap_consecutive_failures "$fails"
  kv_set bootstrap.txt bootstrap_failing "$((fails >= 3 ? 1 : 0))"
  write_status || true
}
trap on_exit EXIT

if ! is_seeded; then
  log "bootstrap: merged stream not seeded; building the first snapshot from $NREG regions"
else
  log "bootstrap: database needs an import and no usable snapshot exists; building one from $NREG regions"
fi

# An old snapshot (other region list, or its diffs pruned) is useless now.
# Remove the marker first so init never imports a file we are replacing.
rm -f "$SNAP/ready" "$SNAP/merged.osm.pbf" "$SNAP"/*.tmp
BUILD=$SNAP/build
mkdir -p "$EXT" "$BUILD"

# Optional free-space guard: downloads plus the merge output need about 2 x E.
need=0
for ((i = 0; i < NREG; i++)); do
  len=$(curl -fsSIL --connect-timeout 20 "${EXTRACT_URLS[i]}" | tr -d '\r' \
    | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -n 1) || len=''
  [[ $len =~ ^[0-9]+$ ]] && need=$((need + len))
done
if ((need > 0)) && ((2 * need > $(free_bytes "$WORK"))); then
  warn "sidecar-work has $(($(free_bytes "$WORK") / 1048576)) MiB free; bootstrap needs about $((2 * need / 1048576)) MiB"
fi

# 1. Download (or reuse a download from a run in the last day that had to
# wait), read s_i from the PBF header, check metadata.
declare -a SEQ PBF
for ((i = 0; i < NREG; i++)); do
  name=$(region_name "$i")
  PBF[i]=$EXT/$name.osm.pbf
  if [ -s "${PBF[i]}" ] && [ -n "$(find "${PBF[i]}" -mmin -1440)" ]; then
    log "$name: reusing ${PBF[i]} downloaded by an earlier run"
  else
    log "$name: downloading ${EXTRACT_URLS[i]}"
    fetch "${EXTRACT_URLS[i]}" "${PBF[i]}" || die "$name: download failed"
    # Warn-only md5 (OSM France .md5 files can be stale; none exists for -latest).
    code=$(http_code "${EXTRACT_URLS[i]}.md5")
    if [ "$code" = 200 ]; then
      exp=$("${CURL[@]}" "${EXTRACT_URLS[i]}.md5" | awk '{print $1}')
      act=$(md5sum "${PBF[i]}" | awk '{print $1}')
      if [ "$exp" = "$act" ]; then log "$name: md5 ok"; else warn "$name: md5 mismatch (stale .md5?), continuing"; fi
    else
      log "$name: no .md5 (HTTP $code), skipping check"
    fi
  fi
  SEQ[i]=$(osmium fileinfo -g header.option.osmosis_replication_sequence_number "${PBF[i]}")
  [[ ${SEQ[i]} =~ ^[0-9]+$ ]] || die "$name: no replication sequence in PBF header"
  # One pass over the file; -g takes a single variable, so read the JSON.
  meta=$(osmium fileinfo -e -j "${PBF[i]}" | tr -d ' \n' \
    | sed -n 's/.*"all_objects":{\([^}]*\)}.*/\1/p')
  if [ "$meta" = '"version":true,"timestamp":true,"changeset":true,"user":true,"uid":true' ]; then
    meta=full
  else
    warn "$name: not every object has full metadata: $meta"
  fi
  log "$name: s=${SEQ[i]} metadata=$meta"
done

# 2. S = max(s_i). With a live stream, S must not be ahead of its head.
S=${SEQ[0]}
for s in "${SEQ[@]}"; do ((s > S)) && S=$s; done
log "snapshot sequence S=$S"
if is_seeded && ((S > head)); then
  RESULT=waiting
  log "S=$S is ahead of the merged head $head; keeping the downloads and retrying at the next tick"
  exit 0
fi

# 3. Roll each region forward to S, deleting each original once its new file is complete.
declare -a AT_S
for ((i = 0; i < NREG; i++)); do
  name=$(region_name "$i")
  if ((SEQ[i] == S)); then AT_S[i]=${PBF[i]}; continue; fi
  log "$name: rolling forward $((S - SEQ[i])) minutes (${SEQ[i]}+1..$S)"
  fetch_and_merge_range "$i" $((SEQ[i] + 1)) "$S" "$BUILD/$name.osc.gz"
  osmium apply-changes --no-progress -O -o "$BUILD/$name.osm.pbf.tmp" -f pbf "${PBF[i]}" "$BUILD/$name.osc.gz"
  mv "$BUILD/$name.osm.pbf.tmp" "$BUILD/$name.osm.pbf"
  rm -f "$BUILD/$name.osc.gz" "${PBF[i]}"
  AT_S[i]=$BUILD/$name.osm.pbf
done

# 4. Merge, with the sequence and timestamp of S in the header.
fetch "${DIFF_URLS[0]}/$(seq_path "$S").state.txt" "$BUILD/S.state.txt" || die "cannot fetch state for $S"
TS=$(state_get "$BUILD/S.state.txt" timestamp)
limit=$(mem_limit)
est=$((100 + 80 * NREG))
if [ "$limit" != max ] && ((est * 1048576 > limit * 8 / 10)); then
  warn "osmium merge of $NREG regions needs about $est MiB, above 80% of the $((limit / 1048576)) MiB memory limit; raise SIDECAR_MEM_LIMIT if bootstrap is killed"
fi
log "merging ${#AT_S[@]} files (estimated peak $est MiB)"
osmium merge --no-progress -O -o "$SNAP/merged.osm.pbf.tmp" -f pbf \
  --output-header="osmosis_replication_sequence_number=$S" \
  --output-header="osmosis_replication_timestamp=$TS" \
  "${AT_S[@]}"
mv "$SNAP/merged.osm.pbf.tmp" "$SNAP/merged.osm.pbf"

# 5. Marker last, so init never imports a partial file. Then drop the inputs.
{ echo "sequenceNumber=$S"; echo "timestamp=$TS"; stamp; } >"$SNAP/ready.tmp"
mv "$SNAP/ready.tmp" "$SNAP/ready"
rm -f "${AT_S[@]}"
log "snapshot ready: $SNAP/merged.osm.pbf ($(du -m "$SNAP/merged.osm.pbf" | cut -f1) MiB, S=$S), container peak memory $(mem_peak_mib) MiB"

# Seed the stream, only if it has no head yet (never move a live head).
if ! is_seeded; then
  mkdir -p "$REPL/minute"
  stamp >"$REPL/regions.txt.tmp"
  mv "$REPL/regions.txt.tmp" "$REPL/regions.txt"
  for n in $((S - 2)) $((S - 1)) "$S"; do
    fetch "${DIFF_URLS[0]}/$(seq_path "$n").state.txt" "$BUILD/seed.state.txt" || die "cannot fetch state for $n"
    publish_seq_state "$n" "$BUILD/seed.state.txt"
  done
  publish_root_state "$S"
  log "seeded merged stream at $S"
fi
rm -rf "$BUILD"
