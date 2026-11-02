# Shared helpers for the sidecar and overpass-init scripts. Sourced, never run.
# Runs inside the b1tw153/overpass-api image as uid 10001. Writes nothing when
# sourced, since overpass-init mounts /work read-only.
#
# Volumes (see DESIGN.md):
#   /work                sidecar-work: extracts, raw diffs, snapshot, status fragments
#   /replication         merged-replication: the merged minute stream, regions.txt, status.txt
#   /opt/overpass/db     overpass-db (read-only in the sidecar)
# shellcheck shell=bash disable=SC2034  # vars are used by the sourcing scripts

WORK=${WORK:-/work}
REPL=${REPL:-/replication}
DB=${DB:-/opt/overpass/db}
SNAP=$WORK/snapshot
RAW=$WORK/raw
EXT=$WORK/extracts
STATUS_DIR=$WORK/status
ROOT_STATE=$REPL/minute/state.txt

KEEP_HOURS=${OVERPASS_CLEANUP_KEEP_HOURS:-72}
SNAPSHOT_KEEP_HOURS=${SNAPSHOT_KEEP_HOURS:-72}
MERGE_LAG_ALERT_MINUTES=${MERGE_LAG_ALERT_MINUTES:-30}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "WARNING: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# Region lists, paired by position.
read -r -a EXTRACT_URLS <<<"${OSM_EXTRACT_URLS:-}"
read -r -a DIFF_URLS <<<"${OSM_DIFF_URLS:-}"
NREG=${#DIFF_URLS[@]}
# Trailing slashes are dropped (OSM France's "copy link" includes one), so
# ".../minute/" and ".../minute" are the same region in URLs and the stamp.
for ((i = 0; i < NREG; i++)); do
  while [[ ${DIFF_URLS[i]} == */ ]]; do DIFF_URLS[i]=${DIFF_URLS[i]%/}; done
done
for ((i = 0; i < ${#EXTRACT_URLS[@]}; i++)); do
  while [[ ${EXTRACT_URLS[i]} == */ ]]; do EXTRACT_URLS[i]=${EXTRACT_URLS[i]%/}; done
done
unset i
check_regions() {
  [ "${#EXTRACT_URLS[@]}" -gt 0 ] || die "OSM_EXTRACT_URLS is not set"
  [ "$NREG" -gt 0 ] || die "OSM_DIFF_URLS is not set"
  [ "${#EXTRACT_URLS[@]}" -eq "$NREG" ] \
    || die "OSM_EXTRACT_URLS has ${#EXTRACT_URLS[@]} entries but OSM_DIFF_URLS has $NREG"
}

# Region name from its extract URL: .../golden_horseshoe-latest.osm.pbf -> golden_horseshoe
region_name() { local b=${EXTRACT_URLS[$1]##*/}; b=${b%.osm.pbf}; echo "${b%-latest}"; }

# The region-list stamp: one URL per line, extracts then diffs.
stamp() { printf '%s\n' "${EXTRACT_URLS[@]}" "${DIFF_URLS[@]}"; }

# 7350827 -> 007/350/827
seq_path() { printf '%03d/%03d/%03d' $(($1 / 1000000)) $(($1 / 1000 % 1000)) $(($1 % 1000)); }

# key=value from a state.txt or status file (backslash escapes removed).
# Empty (and success) if the file doesn't exist.
state_get() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | tr -d "\\\\" | tail -n 1; }

# Epoch seconds of an ISO timestamp, or empty.
epoch() { [ -n "$1" ] && date -u -d "$1" +%s 2>/dev/null; }

# Whole minutes since an ISO timestamp, or empty.
minutes_since() {
  local e
  e=$(epoch "$1") || return 0
  [ -n "$e" ] && echo $(( ($(date +%s) - e) / 60 ))
}

CURL=(curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20)

# fetch URL DEST: download to DEST.tmp then rename. Returns curl's exit code
# (22 for an HTTP error such as 404). Aborts a stalled transfer, not a slow one.
fetch() {
  local rc=0
  mkdir -p "$(dirname "$2")"
  "${CURL[@]}" --speed-limit 1024 --speed-time 60 -o "$2.tmp" "$1" || rc=$?
  if [ "$rc" -eq 0 ]; then mv "$2.tmp" "$2"; else rm -f "$2.tmp"; fi
  return "$rc"
}

# HTTP status of a URL (for telling a 404 from other failures).
http_code() { curl -s -o /dev/null -w '%{http_code}' --connect-timeout 20 -I "$1" || true; }

# Head sequence of a replication folder.
remote_head() {
  local s
  s=$("${CURL[@]}" --max-time 60 "$1/state.txt" | sed -n 's/^sequenceNumber=//p') || return 1
  [[ $s =~ ^[0-9]+$ ]] || return 1
  echo "$s"
}

# Fetch region diffs FROM..TO (cached under $RAW/<i>/) and merge them into one
# simplified change file OUT. Region index i.
fetch_and_merge_range() {
  local i=$1 from=$2 to=$3 out=$4 n f files=()
  for ((n = from; n <= to; n++)); do
    f="$RAW/$i/$(seq_path "$n").osc.gz"
    [ -s "$f" ] || fetch "${DIFF_URLS[$i]}/$(seq_path "$n").osc.gz" "$f" \
      || die "region $(region_name "$i"): cannot fetch diff $n"
    files+=("$f")
  done
  osmium merge-changes --simplify --no-progress -O -o "$out" "${files[@]}"
  rm -f "${files[@]}"
}

# Write a per-sequence state file into the merged stream with its mtime set to
# its own timestamp, so nginx's Last-Modified values are ~60 s apart (the
# overpass service detects the update frequency from them).
publish_seq_state() {
  local n=$1 src=$2 dst ts
  dst="$REPL/minute/$(seq_path "$n").state.txt"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst.tmp"
  ts=$(state_get "$dst.tmp" timestamp)
  touch -d "$ts" "$dst.tmp"
  mv "$dst.tmp" "$dst"
}

# Point the merged root state.txt at sequence N (atomic).
publish_root_state() {
  cp -p "$REPL/minute/$(seq_path "$1").state.txt" "$ROOT_STATE.tmp"
  mv "$ROOT_STATE.tmp" "$ROOT_STATE"
}

merged_head() { state_get "$ROOT_STATE" sequenceNumber; }
is_seeded() { [ -s "$ROOT_STATE" ]; }

# The database's replicate_id, but only if the database was built for the
# current region list (otherwise init will wipe it, so it counts as none).
db_replicate_id() {
  local rid
  [ "$(cat "$DB/regions.txt" 2>/dev/null)" = "$(stamp)" ] || return 0
  rid=$(cat "$DB/replicate_id" 2>/dev/null) || return 0
  [[ $rid =~ ^[0-9]+$ ]] && echo "$rid"
  return 0
}

# Sequence S of the kept snapshot, if it exists and was built for the current
# region list.
snapshot_seq() {
  [ -s "$SNAP/merged.osm.pbf" ] && [ -f "$SNAP/ready" ] || return 0
  [ "$(sed '1,2d' "$SNAP/ready")" = "$(stamp)" ] || return 0
  state_get "$SNAP/ready" sequenceNumber
}

# Small key=value files under $STATUS_DIR (one per job).
kv_get() { state_get "$STATUS_DIR/$1" "$2"; }
kv_set() {
  local f=$STATUS_DIR/$1
  mkdir -p "$STATUS_DIR"
  { grep -v "^$2=" "$f" 2>/dev/null || true; echo "$2=$3"; } >"$f.tmp"
  mv "$f.tmp" "$f"
}

# Rewrite /replication/status.txt from live values plus the jobs' fragments.
write_status() {
  is_seeded || [ -d "$REPL/minute" ] || return 0
  mkdir -p "$STATUS_DIR"
  (
    flock 9
    local head ts rid s ready_epoch
    head=$(merged_head)
    ts=$(state_get "$ROOT_STATE" timestamp)
    rid=$(db_replicate_id)
    s=$(snapshot_seq)
    {
      echo "updated=$(date -u +%FT%TZ)"
      echo "merged_head=$head"
      echo "merged_timestamp=$ts"
      echo "merge_lag_minutes=$(minutes_since "$ts")"
      echo "replicate_id=$rid"
      if [ -n "$rid" ] && [ -n "$head" ]; then echo "overpass_lag_minutes=$((head - rid))"; else echo "overpass_lag_minutes="; fi
      echo "snapshot_seq=$s"
      if [ -n "$s" ]; then
        ready_epoch=$(stat -c %Y "$SNAP/ready")
        echo "snapshot_expires=$(date -u -d "@$((ready_epoch + SNAPSHOT_KEEP_HOURS * 3600))" +%FT%TZ)"
      else
        echo "snapshot_expires="
      fi
      echo "regions=see /replication/regions.txt (extract URLs, then minute replication URLs)"
      cat "$STATUS_DIR/catch-up.txt" "$STATUS_DIR/bootstrap.txt" 2>/dev/null || true
    } >"$REPL/status.txt.tmp"
    mv "$REPL/status.txt.tmp" "$REPL/status.txt"
  ) 9>"$STATUS_DIR/.lock"
}

# Memory limit of this container in bytes, or "max".
mem_limit() { cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max; }

# Peak memory of this container so far, in MiB (cgroup v2), or "?".
mem_peak_mib() {
  local p
  p=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null) || { echo '?'; return; }
  echo $((p / 1048576))
}

# Free bytes on the filesystem holding a path.
free_bytes() { df -B1 --output=avail "$1" | tail -n 1 | tr -d ' '; }
