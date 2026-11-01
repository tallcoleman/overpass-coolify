#!/usr/bin/env bash
# Sidecar healthcheck. Fails only when the service is significantly degraded,
# not on normal lag. Prints the reason.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

fail() { echo "unhealthy: $*"; exit 1; }

[ -s "$ROOT_STATE" ] || fail "merged stream not seeded yet ($ROOT_STATE missing)"
st=$REPL/status.txt
[ "$(state_get "$st" stream_cant_resume)" = 1 ] && fail "stream can't resume (upstream diffs gone); wipe merged-replication and overpass-db"
[ "$(state_get "$st" db_cant_catch_up)" = 1 ] && fail "database can't catch up; wipe overpass-db"
[ "$(state_get "$st" bootstrap_failing)" = 1 ] && fail "bootstrap has failed $(state_get "$st" bootstrap_consecutive_failures) times in a row; check the sidecar log"

head=$(merged_head)
ts=$(state_get "$ROOT_STATE" timestamp)
lag=$(minutes_since "$ts")
[ -n "$lag" ] || fail "cannot read the merged head timestamp"
if ((lag > MERGE_LAG_ALERT_MINUTES)); then
  # A long backlog (after a seed from an extract, or a long stall) is fine
  # while catch-up is working through it: the head's diff is under 5 min old.
  [ -n "$(find "$REPL/minute/$(seq_path "$head").osc.gz" -mmin -5 2>/dev/null)" ] \
    || fail "merged head $head is $lag minutes old (limit $MERGE_LAG_ALERT_MINUTES) and not advancing; check region_unreachable and region_head_* in status.txt for a stalled region"
  echo "healthy: catching up, merged head $head is $lag minutes old"
  exit 0
fi
echo "healthy: merged head $head, $lag minutes old"
