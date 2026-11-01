#!/usr/bin/env bash
# overpass-init: import the sidecar's merged snapshot when the database needs it.
#   - replicate_id present and built for the current region list: nothing to do.
#   - replicate_id present but built for another region list: wipe and re-import.
#   - otherwise: clear any partial import and the diff cache, wait for the snapshot marker, import,
#     then write the region stamp and (last) replicate_id = S.
# Either way, exit only once the merged stream is seeded: overpass detects its
# update frequency from the stream at startup, and if that fails the image's
# entrypoint idles (unhealthy) instead of exiting, so it would never retry.
# /work (sidecar-work) and /replication (merged-replication) are mounted read-only.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
check_regions
BIN=/opt/overpass/bin
DIFF=/opt/overpass/diff
mkdir -p "$DB" "$DIFF"

wait_for_stream() {
  local waited=0
  until is_seeded; do
    ((waited % 300 == 0)) && log "waiting for the sidecar to seed the merged stream ($((waited / 60)) min)"
    sleep 10
    waited=$((waited + 10))
  done
}

if [ -f "$DB/replicate_id" ]; then
  if [ "$(cat "$DB/regions.txt" 2>/dev/null)" = "$(stamp)" ]; then
    log "database already initialized for these regions (replicate_id=$(cat "$DB/replicate_id")); skipping import"
    wait_for_stream
    exit 0
  fi
  log "WARNING: the database was built for a different region list; WIPING it and re-importing"
  log "database regions: $(tr '\n' ' ' <"$DB/regions.txt" 2>/dev/null || echo 'none recorded')"
  log "configured regions: $(stamp | tr '\n' ' ')"
fi

# No valid replicate_id => no valid database; clear files from a failed import.
# Also clear overpass's diff cache: apply_osc_to_db.sh applies every diff in it
# above replicate_id, so diffs left from the old database (another region list,
# or an old stream) would be applied to the new one.
log "clearing database files and the overpass diff cache ..."
find "$DB" "$DIFF" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

log "waiting for the sidecar's snapshot ($SNAP/ready for the current region list) ..."
waited=0
while S=$(snapshot_seq) && [ -z "$S" ]; do
  ((waited % 300 == 0)) && ((waited > 0)) && log "still waiting for the snapshot ($((waited / 60)) min); see the sidecar log"
  sleep 30
  waited=$((waited + 30))
done
PBF=$SNAP/merged.osm.pbf
size=$(stat -c %s "$PBF")
log "snapshot ready: S=$S, $((size / 1048576)) MiB"
if ((20 * size > $(free_bytes "$DB"))); then
  log "WARNING: overpass-db has $(($(free_bytes "$DB") / 1048576)) MiB free; the import may need about $((20 * size / 1048576)) MiB"
fi

case "${OVERPASS_META_MODE:-yes}" in
  yes) META_FLAG=--meta ;;
  *) die "this stack supports OVERPASS_META_MODE=yes only" ;;
esac
COMP=${IMPORT_OSM_COMPRESSION_METHOD:-gz}
FLUSH=${IMPORT_FLUSH_SIZE:-4}
log "importing ($META_FLAG, compression=$COMP, flush-size=$FLUSH) ..."
osmium cat -f osm "$PBF" \
  | "$BIN/update_database" --db-dir="$DB" "$META_FLAG" \
    --flush-size="$FLUSH" \
    --compression-method="$COMP" --map-compression-method="$COMP"

# The stamp first, then replicate_id (the "import completed" marker) last.
[[ $S =~ ^[0-9]+$ ]] || die "snapshot sequence '$S' is not a number"
stamp >"$DB/regions.txt"
echo "$S" >"$DB/replicate_id"
log "database ready: replicate_id=$S"
wait_for_stream
