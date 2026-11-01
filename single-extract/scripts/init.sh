#!/usr/bin/env bash
# Builds the initial Overpass database. The Dockerfile copies it into the
# image at /scripts/init.sh, and the overpass-init service in b1tw153.yml runs
# it on every deploy; it exits at once if the database is already initialized.
# To run it by hand (see README.md, "Running init.sh by hand"):
#
#   docker compose -f b1tw153.yml run --rm --no-deps --build overpass-init
#
# We run import_osm_data.sh's steps ourselves (osmium | update_database, then
# bisect_timestamp.sh) instead of calling it so we can pass --flush-size, skip
# an already-initialized database, clear files left by a failed import, delete
# the downloaded PBF afterwards, and only warn (not fail) on an MD5 mismatch,
# since openstreetmap.fr .md5 files can be stale.
set -euo pipefail

export OVERPASS_DB_DIR="${OVERPASS_DB_DIR:-/opt/overpass/db}"
OVERPASS_DIFF_DIR="${OVERPASS_DIFF_DIR:-/opt/overpass/diff}"
OVERPASS_META_MODE="${OVERPASS_META_MODE:-yes}"
IMPORT_OSM_DATA_SOURCE="${IMPORT_OSM_DATA_SOURCE:-https://download.openstreetmap.fr/extracts/north-america/canada/ontario/golden_horseshoe-latest.osm.pbf}"
OVERPASS_DIFF_URL="${OVERPASS_DIFF_URL:-https://download.openstreetmap.fr/replication/north-america/canada/ontario/golden_horseshoe/minute}"
IMPORT_OSM_COMPRESSION_METHOD="${IMPORT_OSM_COMPRESSION_METHOD:-gz}"
# Millions of elements buffered before flushing during import. Lower =
# lower peak RAM, slower import. update_database's default of 16 gets
# OOM-killed on a small host; drop to 2 or 1 if 4 still OOMs.
IMPORT_FLUSH_SIZE="${IMPORT_FLUSH_SIZE:-4}"

DB="$OVERPASS_DB_DIR"
DIFF="$OVERPASS_DIFF_DIR"
BIN="${OVERPASS_BIN_DIR:-/opt/overpass/bin}"

if [ -f "$DB/replicate_id" ]; then
  echo "Database already initialized (replicate_id present); skipping import."
  exit 0
fi
echo "Empty database detected; importing $IMPORT_OSM_DATA_SOURCE ..."
mkdir -p "$DB" "$DIFF"
# No replicate_id => no valid DB; clear partial files from a failed import.
echo "Clearing stale database files ..."
find "$DB" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

case "${OVERPASS_META_MODE:-no}" in
  yes)   META_FLAG=--meta ;;
  attic) META_FLAG=--keep-attic ;;
  *)     META_FLAG=--data-only ;;
esac
COMP="${IMPORT_OSM_COMPRESSION_METHOD:-lz4}"

PBF="$DB/import-source.osm.pbf"
echo "Downloading source file ..."
curl -fSL --retry 10 --retry-delay 30 --speed-limit 1024 --speed-time 60 -o "$PBF" "$IMPORT_OSM_DATA_SOURCE"

# Warn-only MD5 check. Compare hashes rather than `md5sum -c`, because the .md5
# names the upstream file, not our local import-source.osm.pbf.
MD5_FILE="$PBF.md5"
MD5_CODE=$(curl -sSL --retry 3 --retry-delay 10 -o "$MD5_FILE" -w '%{http_code}' "$IMPORT_OSM_DATA_SOURCE.md5" || true)
if [ "$MD5_CODE" = 200 ]; then
  EXPECTED=$(awk '{print $1}' "$MD5_FILE")
  ACTUAL=$(md5sum "$PBF" | awk '{print $1}')
  if [ "$EXPECTED" = "$ACTUAL" ]; then
    echo "MD5 checksum verified."
  else
    echo "WARNING: MD5 mismatch (expected $EXPECTED, got $ACTUAL); openstreetmap.fr .md5 files can be stale. Continuing."
  fi
elif [ "$MD5_CODE" = 404 ]; then
  echo "No .md5 published for this source; skipping verification."
else
  echo "WARNING: could not fetch .md5 (HTTP ${MD5_CODE:-none}); skipping verification."
fi
rm -f "$MD5_FILE"

FLUSH="${IMPORT_FLUSH_SIZE:-4}"
echo "Importing into database ($META_FLAG, compression=$COMP, flush-size=$FLUSH) ..."
osmium cat -f osm "$PBF" \
  | "$BIN/update_database" --db-dir="$DB" "$META_FLAG" \
      --flush-size="$FLUSH" \
      --compression-method="$COMP" --map-compression-method="$COMP"
rm -f "$PBF"

echo "Determining replicate_id from $OVERPASS_DIFF_URL ..."
# Capture first: a direct `> replicate_id` redirect would create the marker
# even if bisect fails, and the next run would skip the import.
REPLICATE_ID=$(OVERPASS_DB_DIR="$DB" "$BIN/bisect_timestamp.sh" "$OVERPASS_DIFF_URL" "$DIFF")
if [ -z "$REPLICATE_ID" ]; then
  echo "ERROR: bisect_timestamp.sh returned no replicate_id" >&2
  exit 1
fi
echo "$REPLICATE_ID" > "$DB/replicate_id"
echo "Database ready. replicate_id=$REPLICATE_ID"
