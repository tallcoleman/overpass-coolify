#!/usr/bin/env bash
# Sidecar entrypoint. Starts as root only to give uid 10001 the roots of the
# /work and /replication volumes (Docker creates them owned by root, since the
# image has no such directories), then drops to 10001 and execs supercronic.
set -euo pipefail
HERE=$(dirname "$0")
UID_GID=10001

if [ "$(id -u)" = 0 ]; then
  for d in /work /replication; do
    [ "$(stat -c %u:%g "$d")" = "$UID_GID:$UID_GID" ] || chown "$UID_GID:$UID_GID" "$d"
  done
  exec setpriv --reuid="$UID_GID" --regid="$UID_GID" --clear-groups -- bash "$0" "$@"
fi

# shellcheck source=lib.sh
source "$HERE/lib.sh"
check_regions
POLL=${POLL_INTERVAL_MINUTES:-5}
if ! [[ $POLL =~ ^[0-9]+$ ]] || ((POLL < 1 || POLL > 59)); then die "POLL_INTERVAL_MINUTES must be 1..59, got '$POLL'"; fi
((POLL >= 5)) || warn "POLL_INTERVAL_MINUTES=$POLL is below 5; OSM France asks clients to poll state.txt at most every 5 minutes"
log "sidecar starting: $NREG regions ($(for ((i = 0; i < NREG; i++)); do printf '%s ' "$(region_name "$i")"; done)), tick every $POLL minutes"

# supercronic, cached on sidecar-work and checked on every start.
SC_VERSION=v0.2.51
SC_SHA1=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89
SC=$WORK/bin/supercronic-$SC_VERSION
mkdir -p "$WORK/bin"
if ! echo "$SC_SHA1  $SC" | sha1sum -c --status - 2>/dev/null; then
  log "downloading supercronic $SC_VERSION"
  fetch "https://github.com/aptible/supercronic/releases/download/$SC_VERSION/supercronic-linux-amd64" "$SC.tmp.dl" \
    || die "cannot download supercronic"
  echo "$SC_SHA1  $SC.tmp.dl" | sha1sum -c --status - || { rm -f "$SC.tmp.dl"; die "supercronic SHA1 mismatch"; }
  chmod +x "$SC.tmp.dl"
  mv "$SC.tmp.dl" "$SC"
fi
find "$WORK/bin" -mindepth 1 -maxdepth 1 ! -name "supercronic-$SC_VERSION" -exec rm -rf {} +

# Region-list check: a stream built for other regions is discarded with the
# snapshot and raw diffs (overpass-init then wipes and re-imports the database).
if [ -n "$(ls -A "$REPL")" ] && [ "$(cat "$REPL/regions.txt" 2>/dev/null)" != "$(stamp)" ]; then
  log "region list changed (or merged-replication has no regions.txt): discarding the merged stream, snapshot and raw diffs, and rebuilding from scratch"
  log "previous regions: $(tr '\n' ' ' <"$REPL/regions.txt" 2>/dev/null || echo none)"
  find "$REPL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  rm -rf "$SNAP" "$EXT" "$RAW" "$STATUS_DIR" "$WORK/tmp"
fi

# One bootstrap run before scheduling; without a seeded stream there is nothing
# to schedule, so exit and let the restart policy retry.
bash "$HERE/bootstrap.sh" || warn "bootstrap failed; it will be retried at the next tick"
is_seeded || die "merged stream is still not seeded; exiting so the container restarts and retries"

cat >/tmp/crontab <<EOF
2-59/$POLL * * * * bash $HERE/catch-up.sh
2-59/$POLL * * * * bash $HERE/bootstrap.sh
EOF
log "starting supercronic with: $(tr '\n' ';' </tmp/crontab)"
exec "$SC" /tmp/crontab
