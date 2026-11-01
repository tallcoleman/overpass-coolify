# Multi-extract design

This document explains how the multi-extract deployment works, what it relies on in OpenStreetMap France's data and in the `b1tw153/overpass-api` image, why it is built the way it is, how much disk and memory it needs, and how it was tested. For setup, configuration, monitoring and recovery, see [`README.md`](README.md).

## How it works

Overpass can follow only one replication stream, but OSM France publishes one stream per region. The stack runs three services on the `b1tw153/overpass-api` image:

- **`sidecar`** builds one merged stream from the regions' streams with `osmium`, scheduled by [supercronic](https://github.com/aptible/supercronic). It also builds the starting snapshot.
- **`overpass-init`** imports the sidecar's snapshot into the database, once.
- **`overpass`** serves the API and follows the merged stream as if it were an ordinary replication server.

```
 download.openstreetmap.fr                sidecar (supercronic)                    overpass
 ─────────────────────────  every tick  ───────────────────────────────   HTTP   ──────────────────
 regionA/minute/NNN.osc.gz  ─────────▶  barrier = min(region heads)  ─────────▶  fetch_osc.sh
 regionB/minute/NNN.osc.gz  ─────────▶  for N in (last+1 .. barrier):            apply_osc_to_db.sh
 regionC/minute/NNN.osc.gz  ─────────▶    delete tie-break, then
                            (5 min by     osmium merge-changes --simplify
                             default)     write N.osc.gz, N.state.txt, then
                                          root state.txt (atomic rename)
```

**Bootstrap** (`sidecar/bootstrap.sh`): download each region's extract, bring them all to the same sequence `S`, and `osmium merge` them into one snapshot PBF. `overpass-init` imports that and sets `replicate_id = S`.

**Catch-up** (`sidecar/catch-up.sh`): at every tick, read each region's head and take the lowest as the barrier `B`. For each minute `N` from the last published one to `B`, download every region's `N.osc.gz`, apply the delete tie-break, merge them with `osmium merge-changes --simplify`, and publish the result in the standard replication layout. Overpass's nginx serves the stream at `/replication/minute`, and `overpass` fetches it from `http://localhost:8080/replication/minute`.

The merged root `state.txt` is the only record of how far the stream has got, and every step is idempotent, so any run can be repeated and a failed run is retried at the next tick.

## What it relies on in OSM France's data

Checked against download.openstreetmap.fr in October and November 2026.

- **All regions share the planet's minute sequence numbers.** OSM France builds each region's diff from the planet minute diff and hardlinks the planet `state.txt` into the region's folder, as the OSM France admin explains in [b1tw153/Overpass-API#24](https://github.com/b1tw153/Overpass-API/issues/24). So region diff `N` covers the same minute in every region, and the merged stream reuses `N`. This is what keeps the design simple.
- **Regions finish at different times.** Each region's diff is generated in turn, and heavy changesets can delay a region by several minutes. Merged diff `N` can only be published once every region has published `N`.
- **Adjacent extracts overlap at their borders**, so the merge has to handle objects that are in more than one region.
- **A region's diff can delete objects outside the region.** It can contain a `delete` for an object that a neighbouring region's diff has as `modify` at the same version, even when the region never had the object. See *The delete tie-break* below.
- **Extracts are `osmium extract -s complete_ways` cuts.** Ways that cross a border are complete in both extracts. Relations are included with only their in-region members. Objects shared by two extracts have the same version, so `osmium merge` removes the duplicates. The diffs come from a different tool (`generator="xmlwriter"`). In every case tested, they were consistent across borders: an edit to a way crossing a border appears in both regions' diffs at the same minute, with the same version and nodes.
- **Extracts and diffs carry full metadata** (version, timestamp, changeset, user, uid) on every object, so `OVERPASS_META_MODE=yes` works. Bootstrap checks each extract with `osmium fileinfo -e -j` and warns if any object lacks metadata.
- **Regions have only `minute/` replication** (no `hour/` or `day/`).
- **Region minute diffs are kept for about 5 weeks.** A sidecar that is down for longer than that can't resume its stream.
- **Extracts are rebuilt every day or so** (between 1 and 1.5 days apart when observed). The extract's sequence number and timestamp are in its PBF header (`osmosis_replication_sequence_number`, `osmosis_replication_timestamp`), and bootstrap reads them from there rather than from the sibling `<region>.state.txt`, since the header can't drift from the data.
- **`.md5` files are unreliable.** `<region>-latest.osm.pbf` and `<region>.osm.pbf` are the same file. Only the plain name has a `.md5`, and it can be stale. Bootstrap downloads `-latest` and checks `<url>.md5` warn-only.
- **OSM France asks clients to poll `state.txt` no more than every 5 minutes** ([osm-fr/infrastructure#668](https://github.com/osm-fr/infrastructure/issues/668)), though diffs are still published every minute. Overpass polling N regional streams directly would multiply the load. The sidecar polls each region once per tick, and Overpass polls only the local stream.

## What it relies on in the b1tw153 image

Checked in `0.7.62.11-r21`.

- The image contains `osmium-tool` (1.15.0), `curl`, `bash` and `perl` (with `IO::Compress::Gzip`), but no Python, and runs as uid/gid 10001. The sidecar therefore needs no image of its own. The image is published for `linux/amd64` only, so on Apple Silicon set `DOCKER_DEFAULT_PLATFORM=linux/amd64` (it runs under emulation).
- `fetch_osc.sh` rejects any `OVERPASS_DIFF_URL` that doesn't start with `http://` or `https://`, so the stream must be served over HTTP (`file://` doesn't work). It requires a `Last-Modified` header on `state.txt`, and supports only 60, 3600 and 86400 second intervals, so the merged stream must stay minute-numbered.
- `run_osm3s.sh` detects the update frequency at startup from the `Last-Modified` times of the three newest per-sequence state files (`N`, `N-1`, `N-2`), averaging the gaps: under 30 minutes means minutely. `OVERPASS_UPDATE_FREQUENCY` is always overwritten by this, so it isn't set.
- If frequency detection fails (for example against an empty stream), the entrypoint stops its processes and idles, unhealthy, instead of exiting. A restart policy never retries it, so `overpass` must not start before the stream is seeded.
- `apply_osc_to_db.sh` applies every diff in `/opt/overpass/diff` above `replicate_id`, not only those `fetch_osc.sh` has checked against the source. Old cached diffs would be applied to a re-imported database, so init clears that cache whenever it clears the database.
- nginx serves `/opt/overpass/static` at `/` and starts before the Overpass processes.
- After the stream has stalled for more than about 45 minutes, `fetch_osc.sh` backs off to polling every 20 minutes (`PHASE3_DELAY=1200`), so `overpass` can trail a resumed stream by that much.

## Design decisions

### Bootstrap at the newest extract

Each extract is at its own sequence `s_i`. Bootstrap picks `S = max(s_i)`, rolls every older extract forward with its own region's diffs (`merge-changes --simplify`, then `apply-changes`), and merges the results. This is deterministic, unlike starting at `min(s_i)` and relying on Overpass replaying diffs over data that already has them.

If the stream already exists, `S` must not be past its head. Bootstrap then waits for catch-up to advance instead of failing.

### The delete tie-break

`osmium merge-changes --simplify` keeps the highest version of each object, and on a tie keeps whichever input file comes last. At sequence 7351478, way 33957643 (a road entirely inside `central_ontario`) is `modify` v10 in the planet diff and in `central_ontario`, but `delete` v10 in `golden_horseshoe`, which never had the way. With `golden_horseshoe` last, a plain merge deletes a live road.

A real OSM deletion always has a new version, so a `delete` tied with a non-delete at the same version is always a region-side artefact. Before merging, `sidecar/tiebreak.pl` removes from each region's diff any `delete` whose type, id and version appear as a create or modify in another region's diff for the same minute. The merge of the filtered files then doesn't depend on input order. An object that leaves every region gets only deletes and is still removed.

These ties aren't rare: there were 25 in 2,373 minutes of `golden_horseshoe` + `central_ontario`, from both regions, including v1 creates and a relation. Without the filter, the merged database lost 10–15 live objects over that period.

### Region-list stamp

The configured region lists, normalized to one URL per line, are the "stamp". It is stored with the stream (`merged-replication/regions.txt`), with the snapshot (its `ready` marker) and with the database (next to `replicate_id`). Each consumer compares the stored stamp with the configured lists, and a missing stamp next to existing data counts as a mismatch.

On a mismatch, the sidecar discards the stream and snapshot and bootstraps again, and init wipes and re-imports the database. This is the only case where the stack wipes the database on its own, and it logs a warning when it does. The stream's stamp lives with the stream, not in `sidecar-work`, so wiping `sidecar-work` alone triggers nothing.

### Seeding the stream

The stream is seeded only when it doesn't exist yet. An existing head is never overwritten, since re-seeding a live stream at a later `S'` would make the database skip the diffs in between. Seeding writes the per-sequence `state.txt` files for `S-2`, `S-1` and `S`, each with its mtime set to its own `timestamp=`, then the root `state.txt`. Without those three files, frequency detection fails and `overpass` idles.

Catch-up sets each published `N.state.txt`'s mtime the same way. Diffs are published in bursts, but nginx's `Last-Modified` values stay about 60 seconds apart, so an `overpass` restart right after a burst or a long stall still detects a minutely stream.

### Publishing in bursts

The sidecar ticks every `POLL_INTERVAL_MINUTES` (default 5) and publishes everything up to the barrier at once. Per region per hour this is 12 root `state.txt` requests and 60 diff requests, plus 60 per-sequence `state.txt` requests in total (they're identical across regions, so only the first region's is fetched). The cost is about 1–2 minutes of extra average lag. A one-minute tick with cached heads makes the same requests and barely reduces lag, because the barrier waits for the region polled longest ago. Reducing lag properly would need extra probe requests to OSM France.

### Pruning and snapshot retention

Merged diffs are pruned after `OVERPASS_CLEANUP_KEEP_HOURS`, with a guard: merged diff `N` is never pruned if `N > replicate_id`, or if `N > S` of a kept snapshot. The extracts are already up to a day old when bootstrap runs, so without the guard, diffs since `S` could be pruned while the snapshot still looks usable. No disk cap overrides the guard. The merged diffs take about 0.5 MB per hour, so even a long `overpass` outage costs little.

The snapshot is kept for `SNAPSHOT_KEEP_HOURS` after an import, so a later re-import (after a database wipe) doesn't need a new bootstrap. It is never expired while the database still needs an import. Expiry runs before pruning, so the guard releases the diffs it was holding. Raw region diffs are deleted once merged.

### When things go wrong

- **A region stalls:** the barrier holds the whole stream back, and the sidecar turns unhealthy once the merged head is older than `MERGE_LAG_ALERT_MINUTES` and not advancing. Dropping the stalled region automatically would mean a full rebuild, so it stalls and alerts instead. An advancing backlog (after a seed from an old extract, or after a stall clears) counts as healthy.
- **Upstream diffs are gone:** a 404 for a diff at or below that region's head means OSM France has pruned it. After 3 ticks in a row, the sidecar flags that the stream can't resume. Recovery is a manual wipe of the stream and the database.
- **The database can't catch up:** if the stream no longer has `replicate_id + 1`, which can only happen after the stream was wiped or re-seeded by hand, the sidecar flags it. Recovery is a manual wipe of the database.
- **Corruption:** a corrupt database still has its `replicate_id`, so nothing detects it automatically. Recovery is a manual wipe of the database. There is no on-demand rebuild flag.
- **Bootstrap fails:** usually an OOM kill. It retries at every tick, catch-up keeps running, and the sidecar turns unhealthy after 3 failures in a row. A run killed mid-way leaves only `.tmp` files, which are never renamed into place.

The recovery steps are in the README.

### Serving the stream publicly

The merged stream is served by `overpass`'s own nginx, so it is public at `https://<domain>/replication/`. That is intended: the diffs are combined public data, and `status.txt` can be checked from a browser. A separate server in the sidecar would need a second process in an image built for one.

### supercronic

supercronic runs `bootstrap.sh` and `catch-up.sh` at every tick. It doesn't start a job while the previous run of that job is still going, waits for running jobs on SIGTERM, and logs each job's output and exit status. It keeps no state, since all state is in files. It is one static binary, downloaded when the image is built and checked against a pinned SHA1, so container starts don't depend on GitHub. A plain `while sleep` loop would work, but it would lack overlap protection, wall-clock alignment, per-job exit logging and graceful shutdown.

### Scripts baked into a thin image

Coolify deploys the stack from the public Git repo with the Docker Compose build pack, which builds `build:` services from the checkout. `Dockerfile` starts `FROM` the upstream image (`OVERPASS_IMAGE`, passed as a build arg) and adds supercronic and `sidecar/` at `/scripts`. `sidecar` and `overpass-init` both build it, and the second build is a cache hit. `overpass` runs the upstream image unchanged. So all three services still share one Overpass build, and one variable picks it.

Both services pin `platform: linux/amd64`, because the upstream image and the supercronic binary are amd64-only. Without it, a build on an arm64 host looks for an arm64 base and fails.

This replaced two earlier approaches:

- **Scripts inlined under `configs:`.** For Coolify's paste-a-compose deploy, a generator inlined each script as `configs` `content` with every `$` doubled, since Compose interpolates `$` everywhere in the file. It worked, but the deployed file was 950 generated lines, and each change needed a regeneration step.
- **Bind-mounting the scripts from the checkout.** Coolify supports this only with "Preserve repository during deployment" turned on, and a missing file source turns into a directory. A built image has neither problem, and the scripts in a running container can't drift from the image.

### Service wiring

- The sidecar starts as root only to `chown` the two volume roots it writes (Docker creates them root-owned), then drops to uid 10001 with `setpriv`. So nginx in `overpass`, also uid 10001, can read the stream.
- `overpass-init` uses `depends_on: sidecar: condition: service_started`, not `service_healthy`, and waits for the snapshot marker itself. After a later database wipe the sidecar is already running, and a stalled region would otherwise block the stack from starting. Init also waits until the stream is seeded before exiting, so `overpass` never starts against an empty stream.
- `overpass` uses `depends_on: overpass-init: condition: service_completed_successfully, restart: true`. With `restart: true`, Compose stops `overpass` before it recreates `overpass-init` after a region-list change. Without it, only the sidecar and init are recreated (`overpass` doesn't use the region variables), and init would wipe the database under a running server.
- `overpass`'s healthcheck doesn't depend on the sidecar, so a stalled merge leaves the API serving slightly old data rather than taking it offline.
- The sidecar's own healthcheck replaces the image's API check, which would always fail there, and has a 30-minute start period for the first bootstrap.
- `stop_grace_period` is 120 s for `overpass` (so an in-progress diff update finishes) and 60 s for the sidecar (longer than a normal catch-up run).

### Meta mode only

`merge-changes --simplify` keeps only the last version of each object within a minute, and extracts carry no history, so the design supports `OVERPASS_META_MODE=yes` but not attic mode.

## Sizing

### Disk

Budget about 20 × `E` for the whole stack, where `E` is the total size of the extracts. The import is the peak, when the database reaches 15–20 × `E` while the snapshot (about `E`) still exists. For three Ontario/Quebec regions (`E` = 346 MB), the measured peak was 5.3 GB.

Database sizes, imported with `update_database --meta --flush-size=4` and gz compression:

| Input | PBF | Database | Ratio |
| -- | -- | -- | -- |
| `outaouais` | 50 MB | 1.04 GB | 21 × |
| `golden_horseshoe` | 175 MB | 3.63 GB | 21 × |
| merged `golden_horseshoe` + `eastern_ontario` + `outaouais` | 338 MB | 4.83 GB (4.92 GB at peak) | 14 × |

`nodes.map` makes up 55–70% of each database, and it grows with how much of the node-ID range the data touches, not with the object count. So the ratio falls as the area grows, and the merged database is smaller than the sum of single-region ones. 20 × is a safe figure for regions of a few hundred MB and overestimates for large countries. Areas (`OVERPASS_AREAS=yes`) add under 0.1%.

| Phase | Disk in use |
| -- | -- |
| Sidecar bootstrap (merge step) | about 2 × `E` |
| Import | about `E` (snapshot) + 15–20 × `E` (database) |
| Steady state | database + `E` (until the snapshot expires) + about 100 MB of diffs |
| Region-list change | as import: the old database is wiped before the new import, so two never exist at once |

The merged stream and `overpass-diff` hold about 35 MB each for 72 hours of minutes, mostly filesystem block overhead.

### Memory

Only bootstrap needs real memory. Catch-up uses tens of MiB. Peak resident memory of osmium 1.15.0, measured under emulation:

| Step | Peak RSS |
| -- | -- |
| `osmium merge`, 1 input (50 MB or 175 MB) | 108–134 MiB |
| `osmium merge`, 3 inputs | 340 MiB |
| `osmium merge`, 6 inputs | 563 MiB |
| `osmium apply-changes`, 812 merged minutes of `golden_horseshoe` (71 KB gz) | 131 MiB |
| `osmium apply-changes`, 54 planet minutes (2.0 MB gz) | 169 MiB |
| `osmium merge-changes --simplify`, one minute of 3 regions | 8 MiB |

`osmium merge` streams its inputs, so its memory depends on the number of regions, not their size: about 100 MiB + 80 MiB per region. `apply-changes` holds the whole change set, about 130 MiB + 20 MiB per MiB of gzipped diff, and bootstrap applies one region at a time, so only the most-behind region counts. That's negligible for Ontario-sized regions, but a busy country a day behind could need 1 GiB or more.

The default `SIDECAR_MEM_LIMIT` of 1 GiB fits about 10 regions. Raise it to 2g for more regions or country-sized ones. Bootstrap reads the limit from the cgroup and warns before merging when the estimate is above 80% of it. `memswap_limit` is set to the same value, so a runaway job is killed and retried instead of swapping the host. The sidecar's peak never overlaps the import's, because init waits for the snapshot marker, which is written after the merge.

When sizing the host, add the sidecar's limit to the Overpass dispatcher's `DISPATCHER_BASE_SPACE` (2 GiB here) and leave room for `update_database` during imports (the import of two regions raised host memory by about 1.6 GB).

## How Coolify behaves

Found with probe deployments on Coolify's paste-a-compose flow, before the move to Git deploys (the findings about containers and health don't depend on how the file reaches Coolify):

- `mem_limit`/`memswap_limit`, `depends_on: restart: true` and top-level `configs:` with inline `content` are kept as written. `build:` with `dockerfile_inline` also works, but isn't used.
- Coolify shows a container in Docker's `starting` health state as healthy, so a long first bootstrap doesn't fail the deployment. Once Docker reports `unhealthy`, Coolify shows the container as "Running (unhealthy)" and the stack as degraded, and it turns healthy again as soon as the check passes.
- A running service with no healthcheck makes the stack status "unknown", so every long-running service needs one.
- An exited one-shot is ignored in the stack status. But a failed `overpass-init` fails the deployment (`overpass` depends on it with `service_completed_successfully`), leaves `overpass` created but not started, and shows the stack as "Starting" indefinitely.
- Coolify names volumes `<resource-uuid>_<volume>`.
- Coolify's Traefik proxy doesn't route to a container that isn't Docker-healthy, and answers 503 "no available server" instead.

## Validation

### Prototype

The merge was first prototyped as standalone scripts on real data for `golden_horseshoe` + `central_ontario` (not included in this repo). The reference for each check was `ontario` at the same sequence, cut with `osmium extract -s complete_ways` once per region polygon and merged, which is how OSM France builds the regions. Comparisons were `osmium diff` on full files (versions, metadata, tags, node lists, coordinates, members), plus `osmium check-refs`.

| Check | Result |
| -- | -- |
| Tie-break regression at 7351478, both input orders | Way 33957643 is `modify` v10 both ways, and the two outputs are byte-identical. A plain merge with `golden_horseshoe` last deletes it. |
| Snapshot vs reference | 32,318,765 objects identical, 0 different, 0 missing way nodes |
| Snapshot + 2,373 merged diffs vs reference | 32,321,364 identical, 0 different, 0 missing way nodes |
| Same, without the tie-break | 10–15 objects missing, depending on input order |
| 3-hour live run (37 ticks), then snapshot + 2,680 merged diffs vs reference | 32,321,612 identical, 0 different, 0 missing way nodes |
| Bootstrap with each region rolled forward 2,373 minutes vs snapshot + stream | identical |
| Each region rolled forward 2,466 minutes with its own diffs vs OSM France's rebuild | identical (22.2 M and 10.5 M objects) |

The last check covers a case the earlier ones couldn't: an edit that changes a node outside a region's polygon on a way the region keeps. No edit in those 41 hours left the diffs and a fresh cut disagreeing.

Performance under emulation: bootstrap of two regions took about 2 minutes, and catch-up about 2.5 s per merged minute, mostly network round trips. A normal 5-minute tick takes about 12 s.

### Local stack

With `golden_horseshoe` + `central_ontario` under `docker compose`: bootstrap took 83 s, the import 6 minutes under emulation, and `overpass` detected a minutely stream and followed it. Queries at the border returned the expected objects: cities on both sides, all nodes of 1,510 ways in a box straddling the border, and `is_in` areas for points in both regions.

Failure cases, each run on the local stack:

| Case | Result |
| -- | -- |
| Catch-up run outlasting its tick | supercronic skipped the overlapping ticks and started the next run after it ended |
| Sidecar killed mid-merge | stream consistent, next run resumed at the right minute |
| One region unreachable | nothing merged, sidecar unhealthy after the lag limit, recovered at the next tick once fixed |
| Diff 404 below a region's head | "stream can't resume" after 3 ticks, cleared by a tick without the 404 |
| Whole-stack restart | no import, no bootstrap, healthy within 40 s |
| Stream wiped while the database was behind the new seed | "database can't catch up" at the first tick |
| Database wiped, snapshot kept | no bootstrap, re-import, `overpass` followed the stream |
| Snapshot expired, database wiped, sidecar limited to 200 MiB | bootstrap OOM-killed 3 times, "bootstrap has failed 3 times in a row", rebuilt once the limit was raised |
| `sidecar-work` wiped | supercronic downloaded again, nothing else triggered (since then, supercronic is part of the image) |
| Region-list change, and back | stream, snapshot and database rebuilt each time, with the right objects present and absent |

These tests found and fixed: init exiting before the stream was seeded, stale cached diffs applied after a re-import, init wiping the database under a running `overpass` (fixed with `restart: true`), and `status.txt` not being rewritten during a long catch-up.

### Coolify

Deployed on Coolify with `golden_horseshoe` + `eastern_ontario`, alongside a single-extract `golden_horseshoe` deployment. Bootstrap took 56 s and the import 16 minutes. Three hours later the merge lag was 1 minute and the Overpass lag 2 minutes. `tools/compare.sh` gave identical counts on both deployments for every query inside `golden_horseshoe` (Toronto, Hamilton, Oakville highways, the east-edge box, cities and towns west of the border, boundary relations), and the expected extra data in `eastern_ontario` (60,896 ways around Kingston, against none). Adding `outaouais` later rebuilt everything in 17.5 minutes.

## Alternatives considered

- **Overpass polling each region directly.** Not possible: one Overpass database follows exactly one replication stream.
- **Cutting the planet diffs instead of merging regional ones.** Fetch the planet minute diffs and cut them with `osmium extract` using the union of the regions' polygons. This avoids the barrier and the per-region requests, but downloads the full planet diff every minute and makes the deployment responsible for the clipping rules. It remains a fallback if regional timing proves troublesome.
- **A plain `while sleep 300` loop** instead of supercronic. It needs no extra binary, but lacks overlap protection, wall-clock alignment, per-job exit logging and graceful shutdown.
- **Serving the stream from the sidecar**, to keep it internal, or **over `file://`**. Not needed, since the public stream is fine, and `fetch_osc.sh` rejects `file://`.
- **A sidecar image published to a registry.** It would need a publishing pipeline and a second version to keep in step with the upstream image. A thin image built on deploy (see *Scripts baked into a thin image*) gives the same result without one.
