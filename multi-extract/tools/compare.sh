#!/usr/bin/env bash
# Compare two Overpass endpoints over the same queries.
# Usage: tools/compare.sh A B
#   e.g. tools/compare.sh https://overpass-a.example.org https://overpass-b.example.org
# The queries are written for A = a single-extract golden_horseshoe deployment and
# B = a multi-extract golden_horseshoe + eastern_ontario one. Edit them for other regions.
# Counts can differ slightly if the two databases are at different minutes;
# the osm_base timestamps are printed first so you can tell.
# Rows marked "B higher" cover eastern_ontario (outside golden_horseshoe), so B has more.
set -uo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 A B   (two Overpass base URLs, e.g. https://overpass.example.org)" >&2
  exit 2
fi
A=${1%/} B=${2%/}

q() { curl -sS -g --max-time 180 --data-urlencode "data=$2" "$1/api/interpreter"; }
base() { q "$1" '[out:json];node(1);out ids;' | sed -n 's/.*"timestamp_osm_base": *"\([^"]*\)".*/\1/p'; }
count() { q "$1" "[out:csv(::count;false)][timeout:170];$2 out count;" | head -n 1; }

echo "osm_base  A=$(base "$A")  B=$(base "$B")"
printf '%-46s %10s %10s\n' query A B
while IFS='|' read -r name body; do
  [ -n "$name" ] || continue
  a=$(count "$A" "$body"); b=$(count "$B" "$body")
  mark=''; [ "$a" = "$b" ] || mark='  <-- differs'
  printf '%-46s %10s %10s%s\n' "$name" "$a" "$b" "$mark"
done <<'Q'
Toronto downtown nwr (43.63,-79.42,43.67,-79.36)|nwr(43.63,-79.42,43.67,-79.36);
Hamilton nwr (43.23,-79.90,43.27,-79.84)|nwr(43.23,-79.90,43.27,-79.84);
Oakville highways|way[highway~"^(motorway|trunk|primary)$"](43.40,-79.75,43.50,-79.60);
border box ways, golden_horseshoe east edge|way(43.95,-78.55,44.10,-78.25);
Kingston ways, B higher (eastern_ontario only)|way(44.2,-76.6,44.3,-76.4);
cities and towns, west of the border|node[place~"^(city|town)$"](42.8,-80.6,44.6,-78.6);
cities and towns, east of the border, B higher|node[place~"^(city|town)$"](43.9,-78.4,46.3,-74.3);
named boundary relations|rel[boundary=administrative][name](43.4,-80.0,44.0,-79.0);
Q
