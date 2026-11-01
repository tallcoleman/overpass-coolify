#!/usr/bin/env bash
# Catch-up: one tick of the ongoing merge, run by supercronic.
#   1. Read each region's head (one state.txt per region); barrier = min(heads).
#   2. For each N from the merged head + 1 to the barrier: fetch every region's
#      N.osc.gz, apply the delete tie-break, merge, publish (osc, per-sequence
#      state, root state).
#   3. Expire the snapshot, prune merged diffs (guarded), check the database
#      can still catch up, and rewrite status.txt.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
check_regions

is_seeded || { log "merged stream not seeded yet (bootstrap pending); nothing to do"; exit 0; }
[ "$(cat "$REPL/regions.txt" 2>/dev/null)" = "$(stamp)" ] \
  || die "merged stream was built for another region list; restart the sidecar to rebuild it"
trap 'write_status || true' EXIT
mkdir -p "$STATUS_DIR"

last=$(merged_head)
B=''
heads=()
for ((i = 0; i < NREG; i++)); do
  name=$(region_name "$i")
  if ! h=$(remote_head "${DIFF_URLS[i]}"); then
    kv_set catch-up.txt region_unreachable "$name"
    die "$name: cannot read ${DIFF_URLS[i]}/state.txt"
  fi
  heads+=("$name=$h")
  kv_set catch-up.txt "region_head_$name" "$h"
  if [ -z "$B" ] || ((h < B)); then B=$h; fi
done
kv_set catch-up.txt region_unreachable ''
kv_set catch-up.txt barrier "$B"
kv_set catch-up.txt catchup_last_run "$(date -u +%FT%TZ)"
log "tick: merged head $last, region heads ${heads[*]}, barrier $B, merging $((B > last ? B - last : 0))"

# A database behind the oldest kept diff can never catch up (only possible if
# the stream was wiped or re-seeded while the database was behind). Checked
# before and after merging, since a long backlog can take this run an hour.
check_db() {
  local rid head
  rid=$(db_replicate_id)
  head=$(merged_head)
  if [ -n "$rid" ] && ((rid < head)) && [ ! -f "$REPL/minute/$(seq_path $((rid + 1))).osc.gz" ]; then
    kv_set catch-up.txt db_cant_catch_up 1
    log "ERROR: the database (replicate_id=$rid) needs merged diff $((rid + 1)), which is no longer in the stream. Stop the stack, delete the overpass-db volume, and redeploy; the sidecar then builds a new snapshot and overpass-init re-imports."
  else
    kv_set catch-up.txt db_cant_catch_up 0
  fi
}
check_db
write_status

TMP=$WORK/tmp/catch-up
missing=''
merged=0 drops=0
for ((n = last + 1; n <= B; n++)); do
  rm -rf "$TMP" && mkdir -p "$TMP/filtered"
  sp=$(seq_path "$n")
  inputs=()
  for ((i = 0; i < NREG; i++)); do
    f="$RAW/$i/$sp.osc.gz"
    if [ ! -s "$f" ] && ! fetch "${DIFF_URLS[i]}/$sp.osc.gz" "$f"; then
      code=$(http_code "${DIFF_URLS[i]}/$sp.osc.gz")
      [ "$code" = 404 ] || die "$(region_name "$i"): diff $n failed with HTTP $code; retrying at the next tick"
      missing="$(region_name "$i") diff $n"
      break 2
    fi
    inputs+=("$f")
  done
  fetch "${DIFF_URLS[0]}/$sp.state.txt" "$TMP/state.txt" || die "cannot fetch state for $n"

  # Tie-break: drop deletes that another region has as create/modify at the same version.
  perl "$(dirname "$0")/tiebreak.pl" "$TMP/filtered" "${inputs[@]}" 2>"$TMP/drops"
  if [ -s "$TMP/drops" ]; then
    while read -r line; do log "tie-break $n: ${line//$RAW\//}"; done <"$TMP/drops"
    drops=$((drops + $(wc -l <"$TMP/drops")))
  fi
  filtered=()
  for ((i = 1; i <= NREG; i++)); do filtered+=("$TMP/filtered/$i.osc.gz"); done
  osmium merge-changes --simplify --no-progress -O -o "$TMP/merged.osc.gz" "${filtered[@]}"

  # Publish in order: osc, per-sequence state, root state.
  dst=$REPL/minute/$sp.osc.gz
  mkdir -p "$(dirname "$dst")"
  mv "$TMP/merged.osc.gz" "$dst"
  publish_seq_state "$n" "$TMP/state.txt"
  publish_root_state "$n"
  rm -f "${inputs[@]}"
  merged=$((merged + 1))
  ((merged % 10)) || write_status
done
rm -rf "$TMP"
head=$(merged_head)
log "merged $merged, tie-break drops $drops, merged head $head"

# Missing upstream diff at or below a region's head: most likely pruned after
# long downtime. Count ticks; at 3 the stream can't resume.
if [ -n "$missing" ]; then
  ticks=$(kv_get catch-up.txt missing_diff_ticks)
  ticks=$((${ticks:-0} + 1))
  kv_set catch-up.txt missing_diff_ticks "$ticks"
  warn "$missing is gone upstream (HTTP 404) although the region's head is past it ($ticks consecutive ticks)"
  if ((ticks >= 3)); then
    kv_set catch-up.txt stream_cant_resume 1
    log "ERROR: the merged stream can't resume: upstream no longer has the diffs it needs. Stop the stack, delete the merged-replication and overpass-db volumes, and redeploy."
  fi
else
  kv_set catch-up.txt missing_diff_ticks 0
  kv_set catch-up.txt stream_cant_resume 0
fi

rid=$(db_replicate_id)

# Expire the snapshot once the database no longer needs it and it is older
# than SNAPSHOT_KEEP_HOURS. Marker first, so init never sees a half-deleted one.
if [ -f "$SNAP/ready" ] && [ -n "$rid" ] \
  && [ -n "$(find "$SNAP/ready" -mmin +$((SNAPSHOT_KEEP_HOURS * 60)))" ]; then
  log "snapshot is older than ${SNAPSHOT_KEEP_HOURS}h and the database is imported; deleting it"
  rm -f "$SNAP/ready"
  rm -f "$SNAP/merged.osm.pbf"
fi

# Prune merged diffs older than KEEP_HOURS, but never one the database or a
# kept snapshot still needs (N > replicate_id or N > S).
limit=$((head - KEEP_HOURS * 60))
[ -n "$rid" ] && ((rid + 1 < limit)) && limit=$((rid + 1))
S=$(snapshot_seq)
[ -n "$S" ] && ((S + 1 < limit)) && limit=$((S + 1))
mkdir -p "$WORK/tmp"
(cd "$REPL/minute" && find . -mindepth 3 -maxdepth 3 -type f \( -name '*.osc.gz' -o -name '*.state.txt' \) \
  | awk -F/ -v lim="$limit" '{ n = $2 * 1000000 + $3 * 1000 + substr($4, 1, 3); if (n < lim) print }' \
  >"$WORK/tmp/prune.list" && xargs -r rm -f <"$WORK/tmp/prune.list")
pruned=$(wc -l <"$WORK/tmp/prune.list")
rm -f "$WORK/tmp/prune.list"
find "$REPL/minute" -mindepth 1 -type d -empty -delete
((pruned == 0)) || log "pruned $pruned merged files below sequence $limit"
# Raw diffs are deleted after each merge; clear any left by a killed run.
[ -d "$RAW" ] && find "$RAW" -type f -mmin +1440 -delete

check_db

[ -z "$missing" ]
