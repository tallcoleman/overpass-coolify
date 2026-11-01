# Multi-extract Overpass deployment

This folder holds a Docker Compose deployment of the [`b1tw153/overpass-api`](https://hub.docker.com/r/b1tw153/overpass-api) image that serves several adjacent OpenStreetMap France extracts as one database, kept current with minutely updates. A sidecar merges the regions' minute diffs into one replication stream, and Overpass follows that stream as if it came from a single extract. It is written for Coolify's paste-a-compose deploy, and runs with plain `docker compose` too. The design, the reasons behind it and the test results are in [`DESIGN.md`](DESIGN.md).

## Files

- `b1tw153-multiregion.yml` is the Compose file to paste into Coolify. It is generated, so don't edit it by hand.
- `compose.template.yml` and `sidecar/` are the sources it is built from. `sidecar/` holds the scripts: `entrypoint.sh`, `bootstrap.sh`, `catch-up.sh` and `health.sh` (the sidecar), `init.sh` (the `overpass-init` command), `lib.sh` (shared helpers) and `tiebreak.pl` (the delete tie-break).
- `build.sh` writes `b1tw153-multiregion.yml` by inlining each script under `configs:` with every `$` doubled, then checks the result with `docker compose config`. `./build.sh --check` fails if the generated file is out of date.
- `tools/compare.sh A B` runs the same count queries against two Overpass endpoints (for example a single-extract and a multi-extract deployment) and marks the rows that differ.

To change a script: edit `sidecar/` or `compose.template.yml`, run `shellcheck -x -P SCRIPTDIR sidecar/*.sh`, then `./build.sh`, and commit both the sources and the generated file.

## Services and volumes

- **`sidecar`** builds the merged stream. At startup it builds a snapshot: it downloads every extract, brings them all to the same sequence `S`, and merges them into one PBF. Then, every `POLL_INTERVAL_MINUTES`, it reads each region's head and merges every minute up to the oldest head (the barrier). The schedule is run by supercronic. The stream is served at `/replication/` by the `overpass` container's nginx.
- **`overpass-init`** is a one-shot. It imports the snapshot when the database is empty, or when the database was built for a different region list, then exits. Otherwise it exits straight away.
- **`overpass`** is the API server. It follows the merged stream at `http://localhost:8080/replication/minute`.

| Volume | Contents | Cost of wiping it |
| -- | -- | -- |
| `overpass-db` | The Overpass database, with `replicate_id` and the region list it was built for | Re-import (about 16 minutes for three Ontario/Quebec regions) |
| `overpass-diff` | Diffs fetched by `overpass` | None; init clears it with the database |
| `sidecar-work` | Downloads, the snapshot (kept `SNAPSHOT_KEEP_HOURS`), cached supercronic | The kept snapshot, so a later re-import has to build a new one |
| `merged-replication` | The merged stream, `regions.txt`, `status.txt` | A new stream, which the database usually can't follow, so wipe `overpass-db` with it |

## Deploying on Coolify

Create a Docker Compose resource from the pasted contents of `b1tw153-multiregion.yml`, and give the `overpass` service its domain with 8080 as the container port (clients use the bare domain, without a port). Then set the environment variables:

| Variable | Default | Meaning |
| -- | -- | -- |
| `OSM_EXTRACT_URLS` | (required) | Space-separated extract URLs, e.g. `https://download.openstreetmap.fr/extracts/north-america/canada/ontario/golden_horseshoe-latest.osm.pbf` |
| `OSM_DIFF_URLS` | (required) | The matching minute replication folders, in the same order, e.g. `https://download.openstreetmap.fr/replication/north-america/canada/ontario/golden_horseshoe/minute` |
| `POLL_INTERVAL_MINUTES` | `5` | Sidecar tick. OSM France asks for no more than one `state.txt` request per 5 minutes, so the sidecar warns below 5 |
| `OVERPASS_CLEANUP_KEEP_HOURS` | `72` | How long merged diffs (sidecar) and fetched diffs (overpass) are kept |
| `SNAPSHOT_KEEP_HOURS` | `72` | How long the snapshot is kept after an import, for a fast re-import |
| `MERGE_LAG_ALERT_MINUTES` | `30` | The sidecar turns unhealthy when the merged head is older than this and not advancing |
| `SIDECAR_MEM_LIMIT` | `1g` | Sidecar memory limit. Raise it for many or large regions |
| `OVERPASS_IMAGE` | `b1tw153/overpass-api:0.7.62.11-r21` | Image for all three services |

Enter the values without quotes. Trailing slashes are fine, so URLs from the download page's "copy link" can be pasted as they are. The regions must be adjacent or overlapping extracts from the same OSM France replication tree, since the merge relies on them sharing planet sequence numbers.

### What a deploy looks like

On a first deploy, or after a region-list change:

1. The sidecar logs `sidecar starting: N regions (...)` and builds the snapshot (about a minute for three regions).
2. `overpass-init` logs `snapshot ready: S=...` and imports it. `overpass` stays stopped meanwhile.
3. Init logs `database ready: replicate_id=S` and exits, and `overpass` starts.
4. The snapshot is as old as the extracts, which can be a day or more, so the first catch-up run merges a long backlog. On the author's deployment, three regions merged about 40 minutes of backlog per minute, so a day's backlog takes about 35 minutes. `status.txt` shows a large `merge_lag_minutes` falling, and the sidecar reports `healthy: catching up` while it advances.

On the author's deployment, host memory peaked at about 1.6 GB above its baseline during the import of two regions. If `overpass-init` is OOM-killed, lower `IMPORT_FLUSH_SIZE` in `compose.template.yml` from 4 to 2 or 1.

A normal redeploy or restart with the same region lists re-imports nothing. Init exits at once and `overpass` resumes from its `replicate_id`.

### Changing the regions

Edit both variables (same order in each) and redeploy. The sidecar sees that the list in `merged-replication/regions.txt` differs, discards the stream and snapshot, and builds new ones. Compose stops `overpass` (because of `depends_on: restart: true`), init logs `WARNING: the database was built for a different region list; WIPING it and re-importing`, and `overpass` starts again once the import is done. On the author's deployment, adding one region to two took 17.5 minutes from deploy to a running server.

## Monitoring

`https://<domain>/replication/status.txt` is rewritten at every tick:

| Field | Meaning |
| -- | -- |
| `merged_head`, `merged_timestamp`, `merge_lag_minutes` | How far the merged stream has got, and how old that minute is. A few minutes is normal (OSM France's publishing delay plus the tick) |
| `replicate_id`, `overpass_lag_minutes` | How far the database has got, and how many minutes it is behind the merged head |
| `region_head_<name>`, `barrier` | Each region's head; the barrier is the lowest. A region whose head stops moving holds the whole stream back |
| `region_unreachable` | The region whose `state.txt` couldn't be read at the last tick, if any |
| `snapshot_seq`, `snapshot_expires` | The kept snapshot, if any, and when it will be deleted |
| `bootstrap_*` | The last snapshot build: start, end, result, consecutive failures |
| `missing_diff_ticks`, `stream_cant_resume`, `db_cant_catch_up`, `bootstrap_failing` | Error flags; see *Recovery* |

The sidecar's healthcheck prints its reason (`docker inspect -f '{{json .State.Health}}' <container>`). It fails only on:

- `merged stream not seeded yet`: normal during the first bootstrap (it has a 30-minute start period).
- `merged head N is M minutes old (limit 30) and not advancing`: a region has stalled, or OSM France has stopped publishing. Check `region_unreachable` and `region_head_*`. It clears by itself when the region resumes. OSM France has stalled for every region at once before, so check its replication pages before assuming a fault here.
- `stream can't resume`, `database can't catch up`, `bootstrap has failed N times in a row`: see below.

`overpass`'s own healthcheck doesn't depend on the sidecar, so a stalled merge leaves the API serving slightly old data rather than taking it offline. After a long sidecar outage, `overpass` polls the stream only every 20 minutes for a while (the image's backoff), so it can trail the resumed stream by that much.

In Coolify, a stack stuck at **"Starting"** long after an import should have finished means `overpass-init` failed (its exit code fails the deployment, and `overpass` is left created but not started). Check the `overpass-init` logs. A sidecar shown as unhealthy makes the stack **degraded**, while `overpass` keeps serving.

## Recovery

Coolify names the volumes `<resource-uuid>_<volume>`, e.g. `<resource-uuid>_overpass-db`; `docker volume ls | grep overpass-db` finds them. For each case below: stop the stack in Coolify, remove the volumes listed with `docker volume rm`, and redeploy.

| Symptom | Remove | What happens next |
| -- | -- | -- |
| Database corrupt (queries fail or `overpass` errors, though `replicate_id` exists); nothing detects this automatically | `overpass-db` | The sidecar rebuilds the snapshot if it's no longer kept, init re-imports, and `overpass` catches up from the stream |
| `db_cant_catch_up=1`: the database needs a merged diff that is no longer in the stream (only after the stream was wiped or re-seeded while the database was behind) | `overpass-db` | As above |
| `stream_cant_resume=1`: upstream no longer has the diffs the stream needs (sidecar down for weeks, longer than OSM France keeps diffs) | `merged-replication` and `overpass-db` | A new snapshot, stream and database |
| `bootstrap_failing=1`: three snapshot builds in a row failed | Nothing; read the sidecar log first | Usually an OOM kill in the merge (raise `SIDECAR_MEM_LIMIT`), a full disk, or a download failing. It retries at every tick, and the flag clears after a success |

Removing `sidecar-work` on its own is always safe. Don't remove `merged-replication` without `overpass-db`. The new stream starts at the new snapshot's sequence, so a database behind that sequence can never catch up (`db_cant_catch_up` is then set).
