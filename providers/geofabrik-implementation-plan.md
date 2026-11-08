# Sidecar in Python, with Geofabrik support: implementation plan

This plan moves the multi-extract sidecar's logic from bash and Perl to Python, and then adds Geofabrik as a second provider next to OpenStreetMap France. It builds on the results in [`geofabrik-test-plan.md`](geofabrik-test-plan.md) (cited by test ID, e.g. D5) and on [`multi-extract/DESIGN.md`](../multi-extract/DESIGN.md). `single-extract/` needs only documentation changes for Geofabrik, listed at the end.

## Goals and constraints

- **Existing OSM France deployments upgrade in place.** Same volumes, file layout, environment variables, merged stream path (`/replication/minute`), `status.txt` keys and region-list stamp. A changed stamp would make the stack wipe and re-import the database on upgrade, so the stamp's bytes must not change.
- **One provider per deployment.** Mixing providers isn't supported, since each provider's diffs match only its own extracts.
- **Correct by construction for Geofabrik.** The merged stream must equal the union of the regions' extracts after every step. The current merge loses live nodes on Geofabrik data (D3, D4 over 96 days), so Geofabrik gets the snapshot-diff merge recommended by D5.
- **Testable without the network or osmium.** Every decision (pairing, barrier, pruning, health, crash recovery) lives in pure functions with unit tests. osmium and HTTP sit behind thin interfaces.
- **Standard library only at runtime.** No pip dependencies in the image. The `osmium` CLI stays the tool for data work, since every test result was obtained with it.
- **Same scheduling model.** supercronic still runs a bootstrap job and a catch-up job at every tick, and every step stays idempotent, so a killed run is retried at the next tick.

## What changes, by provider

| | OSM France (unchanged behaviour) | Geofabrik (new) |
| -- | -- | -- |
| Upstream step | Planet minute; region sequence = planet minute | Daily planet state; per-region counter, planet minute in a `state.txt` comment (A2) |
| Pairing | By sequence number | By planet minute, skipping to the next boundary every region shares (A3) |
| Merged numbering | Reuses the planet sequence | Own contiguous counter |
| Merge | Tie-break, then `osmium merge-changes --simplify` | Roll each region's extract forward, `osmium merge`, `osmium derive-changes` against the previous merged file (D5) |
| State kept in `sidecar-work` | Snapshot until it expires | One extract per region plus the current merged file, always |
| Merged stream path | `/replication/minute` | `/replication/day` |
| Poll interval default | 5 min | 30 min (A4) |
| Lag alert default | 30 min | 72 h (A4, E4) |
| Extract metadata expected | Full | `version` and `timestamp` only (B2) |
| `.md5` check | Warn-only, `-latest` name | Strict, against the dated file (A7) |
| Snapshot for a re-import | Built by bootstrap, kept `SNAPSHOT_KEEP_HOURS` | A hard link to the current merged file, made on demand |

## Architecture

### Layout

```
multi-extract/
  Dockerfile                    adds python3; COPY sidecar/
  sidecar/
    entrypoint.sh               kept: chown volume roots as root, setpriv to 10001, exec python
    overpass_sidecar/
      __main__.py               CLI: entrypoint-setup | bootstrap | catch-up | health | init
      config.py                 env parsing, Region, provider detection, validation, stamp
      log.py                    timestamped log lines in the current format
      fsutil.py                 atomic write/rename, hard links, set mtime, flock, free space
      http.py                   Http interface + urllib implementation (retries, timeouts, UA)
      osmium.py                 Osmium interface + subprocess implementation
      state.py                  state.txt parse/format (incl. comments), seq_path
      stream.py                 merged stream: head, publish, seed, prune plan
      status.py                 status.txt and per-job kv fragments
      providers/
        base.py                 Provider protocol
        osmfr.py
        geofabrik.py
      merge/
        diffmerge.py            OSM France: tie-break + merge-changes (port of tiebreak.pl)
        snapshot.py             Geofabrik: step directories, roll forward, merge, derive
      pairing.py                Geofabrik planet-minute maps, barrier, next common boundary
      bootstrap.py
      catchup.py
      health.py
      init.py                   overpass-init (replaces init.sh)
  tests/
    unit/                       pytest, no network, no osmium
    integration/                needs osmium; runs in the image's test stage
    fixtures/
```

`lib.sh`, `bootstrap.sh`, `catch-up.sh`, `health.sh`, `init.sh` and `tiebreak.pl` are deleted once the Python version reaches parity (phase 1). The compose file calls `python3 -m overpass_sidecar <job>` for the healthcheck and for `overpass-init`, and the crontab calls it for the two jobs.

### Interfaces that tests replace

- **`Http`**: `get_text(url)`, `download(url, dest)` (atomic, via `.tmp`), `head(url)` (status, final URL after redirects, headers), `status(url)`. The real implementation uses `urllib.request` with a 20 s connect timeout, a per-read timeout of 60 s (the equivalent of curl's `--speed-limit 1024 --speed-time 60`), 3 retries with a 5 s delay, and `User-Agent: overpass-coolify-sidecar`. The test implementation serves a fixture directory and records every request, so tests can assert request counts.
- **`Osmium`**: `header(pbf, key)`, `metadata(pbf)`, `apply_changes(pbf, oscs, out)`, `merge(pbfs, out, headers)`, `merge_changes(oscs, out)`, `derive_changes(old, new, out)`. Each runs the CLI with `--no-progress -O`, writes to `<out>.tmp` and renames. Unit tests use a fake that records calls. Integration tests use the real CLI.
- **`Clock`**: `now()`, so health and pruning are testable at chosen times.

### Provider protocol

```python
class Provider(Protocol):
    name: str                         # "osmfr" | "geofabrik"
    stream_dir: str                   # "minute" | "day"
    default_poll_minutes: int         # 5 | 30
    default_lag_alert_minutes: int    # 30 | 4320
    def validate(self, regions: list[Region]) -> None: ...
    def region_name(self, extract_url: str) -> str: ...
    def resolve_extract(self, http, region) -> Download: ...   # URL to fetch, and md5 policy
    def metadata_ok(self, meta: dict) -> bool: ...
    def planet_minute(self, state: State) -> int: ...          # osmfr: sequenceNumber
    merger: Merger                                               # DiffMerger | SnapshotMerger
```

The provider is detected from the URLs' host (`download.openstreetmap.fr` or `download.geofabrik.de`). `OSM_PROVIDER` overrides detection, for mirrors. Mixed hosts are rejected at startup.

## Geofabrik design in detail

### Configuration

Keep the two lists, as A1 suggests: `OSM_EXTRACT_URLS` with `.../<region>-latest.osm.pbf`, and `OSM_DIFF_URLS` with `.../<region>-updates`. Validation checks that each diff URL is its extract URL with `-latest.osm.pbf` replaced by `-updates`, which catches lists in the wrong order. The stamp format stays the same (extract URLs, then diff URLs, one per line).

`POLL_INTERVAL_MINUTES` accepts 1–60 (60 becomes the crontab line `2 * * * *`). The warning below 5 minutes names the provider's own policy.

### Planet-minute maps and pairing

For each region, the sidecar keeps a map from sequence number to `(planet minute, timestamp)` in `/work/regions/<name>/map.tsv`. It's filled from the per-sequence `state.txt` files, one request per new diff, and appended at each tick (A3). These are pure functions in `pairing.py`:

- `boundaries(map) -> set[int]`: the planet minutes the region has a diff ending at.
- `barrier(maps) -> int`: the newest planet minute every region has reached (the minimum of the regions' head minutes).
- `next_step(current, maps) -> int | None`: the smallest planet minute above `current`, at or below the barrier, that is a boundary in every region. A day one region covers with a two-day diff is then merged as one step (A3). The extra planet states of 07-03 and 07-28 were present in every region, so they become ordinary steps.
- `diffs_for(map, from_minute, to_minute) -> list[int]`: the region's sequence numbers to apply for a step.

**Re-initialisation guard (A5).** If a region's head sequence or planet minute goes backwards, or a sequence number is missing below the head and the planet minute jumps by more than 48 h, the sidecar stops merging, sets `region_reinitialised=<name>` in `status.txt` and turns unhealthy. Recovery is the same as for a stream that can't resume: wipe and rebuild. None was seen in 133 days, so detecting it is enough.

### Merged stream

- Served at `/replication/day`, so the `overpass` service's `OVERPASS_DIFF_URL` becomes `http://localhost:8080/replication/day`. In the compose file this is `http://localhost:8080/replication/${MERGED_STREAM:-minute}`, and the sidecar receives the same variable and refuses to start if it doesn't match the provider. That keeps one compose file and turns a mismatch into an error at startup.
- Merged sequence numbers count up from 1000 at the first seed. The value doesn't matter, since the stream and the database are always rebuilt together, but it leaves room for the `S-2` and `S-1` seed files.
- Each merged `state.txt` has the standard `sequenceNumber` and `timestamp` (the planet state's timestamp, the same in every region per A3), plus comments recording the step:

  ```
  # planet minute 7361559
  # region freiburg-regbez 4950
  # region karlsruhe-regbez 4950
  sequenceNumber=1042
  timestamp=2026-11-06T21\:21\:21Z
  ```

- Each state file's mtime is set to its timestamp, as now (`publish_seq_state`). The timestamps are a day apart, so the `overpass` service always detects 86400, even after a Geofabrik burst (F1).

### The daily step (snapshot diff)

State lives in step directories in `sidecar-work`, so that a crash at any point leaves either the old step or the new one complete:

```
/work/merge/
  current -> 1041               symlink, switched atomically
  1041/
    regions/freiburg-regbez.osm.pbf
    regions/karlsruhe-regbez.osm.pbf
    merged.osm.pbf
    step.json                   merged seq, planet minute, region seqs
    COMPLETE
```

One catch-up step from merged sequence `k` (planet minute `P`) to `k+1` (planet minute `P'`):

1. Make `/work/merge/<k+1>.tmp/`.
2. For each region, fetch its diffs for `P → P'` (`diffs_for`), and `apply-changes` them to `current/regions/<name>.osm.pbf`. Several diffs are applied in one call. C3 shows the result is exactly Geofabrik's next extract.
3. `osmium merge` the new region files into `merged.osm.pbf`, with the planet state's sequence and timestamp in the header.
4. `osmium derive-changes current/merged.osm.pbf <k+1>.tmp/merged.osm.pbf` into the merged diff. No `--increment-version`, so the diff looks like Geofabrik's own, which Overpass applied without errors (E5).
5. Write `step.json` and `COMPLETE`, then rename `<k+1>.tmp` to `<k+1>`.
6. Publish the merged diff, its state file and the root `state.txt`, in that order, as now.
7. Switch `current` to `<k+1>` (write a new symlink and rename it over the old one), then delete `<k>`, unless the snapshot hard link for a pending import points into it.

On startup and at each tick, recovery reconciles the stream head with the step directories: a `.tmp` directory is deleted, a complete `<k+1>` whose diff is published becomes `current`, and a complete `<k+1>` whose diff isn't published is published first. These cases are a table of pure decisions (`snapshot.recover(head, dirs)`) with one unit test per row.

With `E` the total size of the region extracts, `sidecar-work` holds about 2 `E` between steps (regions plus merged file) and about 4 `E` during a step. Peak memory is `osmium merge`'s, about 100 MiB + 80 MiB per region (D5, `DESIGN.md`). D5 measured about 30 s per day for two 150 MB regions.

**Backlog.** After downtime, catch-up runs one step per merged sequence until it reaches the barrier, all within one run, writing `status.txt` every few steps as now. Each step is a full merge, so 30 days of backlog for two regions takes about 15 minutes. That's acceptable, and a run killed partway resumes from the last complete step.

### Bootstrap

Bootstrap runs only when the stream isn't seeded (first start, or after a region-list change). A database that needs an import never triggers a rebuild, because the current merged file is always available.

1. For each region, resolve `-latest.osm.pbf` once to the dated file (`HEAD` with redirects, final URL), download the dated file unless it's already cached, and check it strictly against the dated `.md5` (A7). A mismatch deletes the file and fails the run, and the download is retried with backoff (see *Requests to Geofabrik*), not at every tick.
2. Read the sequence from the PBF header (B1) and look up its planet minute in the region's map. Check metadata against `version` and `timestamp` (B2).
3. Pick `P0` as the newest planet minute among the extracts that every region can reach, and roll each older region forward to `P0` with its own diffs. Dated files are skipped on different days for different groups (A6), so the regions' extracts are often a day apart.
4. Merge into `/work/merge/1000/merged.osm.pbf`, mark it complete, point `current` at it, seed the stream at 1000 (with `998` and `999` state files carrying the two earlier planet states' timestamps), and write `regions.txt`.

### Snapshot for overpass-init

When the database needs an import (no `replicate_id` for the current stamp), catch-up hard-links `current/merged.osm.pbf` to `/work/snapshot/merged.osm.pbf` and writes the `ready` marker with the step's sequence and the stamp, under the merge lock. Init imports it as now. The hard link keeps the file alive after the step directory is deleted, costs no disk until then, and is expired as now (`SNAPSHOT_KEEP_HOURS` after the import). `/work/snapshot` and `/work/merge` are on the same volume, so hard links work.

### Locking

The bootstrap and catch-up jobs can run at the same time. For Geofabrik, both take an exclusive `flock` on `/work/merge/.lock` before touching step directories or the snapshot, and a job that can't get it within a few seconds logs and exits, to try again at the next tick. OSM France keeps its current behaviour, in which a long bootstrap doesn't block catch-up.

### Health and status

- `MERGE_LAG_ALERT_MINUTES` defaults to the provider's value (4320 for Geofabrik). The variable keeps its name and meaning.
- "Advancing" becomes "the head's merged diff was published within the last two ticks" (or 5 minutes, whichever is longer). That works for both providers, since a Geofabrik backlog step can take longer than 5 minutes.
- New flags in `status.txt`: `provider`, `region_reinitialised`, `merge_step_seconds`, `planet_minute`, and `region_planet_minute_<name>`. Existing keys keep their names. `merge_lag_minutes` stays in minutes, and `overpass_lag_minutes` is renamed only in documentation, since it counts sequence steps ("days behind" for Geofabrik).

### Pruning (both providers)

Prune merged diffs by their state file's `timestamp`, not by `KEEP_HOURS × 60` sequences (F1): delete diff `N` when its timestamp is older than `KEEP_HOURS` before the head's, subject to the existing guard (never `N > replicate_id`, never `N > S` of a kept snapshot). For OSM France this keeps the same files as now. `stream.prune_plan(files, head, rid, snapshot_seq, keep_hours)` is pure and returns the list to delete.

### Requests to Geofabrik

Geofabrik supports this kind of use. Its [download page](https://www.geofabrik.de/data/download.html) offers daily diffs, and its [technical notes](https://download.geofabrik.de/technical.html) tell users to keep extracts current with `pyosmium-up-to-date`. In a [2018 answer about rate limits](https://help.openstreetmap.org/questions/64487/what-is-geofabrik-download-request-rate-limit/), Geofabrik's Frederik Ramm describes the limit as a bulk allowance of 40 files that refills at about one file an hour, "not counting diff updates, state.txt, HTML pages etc", and says that "if you don't download more than 24 files a day, you should always be fine". The limit isn't published, because it may change, and going over it gives HTTP 429 with no `Retry-After`. The `robots.txt` that disallows these paths (R0) is taken to be aimed at crawlers, not update clients.

So the sidecar's steady-state traffic doesn't count toward the limit, and only extract downloads do:

| Traffic | Per region | Counts toward the limit |
| -- | -- | -- |
| Root `state.txt` | One per tick (48 a day at 30 minutes) | No |
| Per-sequence `state.txt` and diff | One each per day, plus the state files back to the extract at bootstrap (a handful) | No |
| `HEAD` of `-latest.osm.pbf`, the dated extract and its `.md5` | Once per bootstrap | The extract, probably not the `.md5` |

The design keeps extract downloads rare, and makes sure a failure can't turn into repeated downloads:

- **Bootstrap downloads each extract once.** Downloads are kept in `/work/extracts/` and reused by later attempts, as now (under a day old), so a bootstrap that fails after downloading (an OOM kill, a missing diff) retries without downloading again. With Geofabrik the dated file name makes reuse exact: a cached `freiburg-regbez-261106.osm.pbf` is reused only while `-latest` still points at it.
- **Steady state downloads no extracts.** The snapshot-diff merge rolls the stored extracts forward, and a database re-import uses the hard-linked merged file. Only a region-list change, or a wiped `sidecar-work`, downloads extracts again.
- **Failed downloads back off.** An `.md5` mismatch, a truncated transfer or an HTTP 429 records the failure in `bootstrap.txt`, and the next download of that file waits 1, 2, 4… hours (capped at 24), not one tick. A 429 also stops the rest of that bootstrap run. The backoff is a pure function of the failure count and time, with unit tests.
- **Many regions are spread out.** The first bootstrap downloads at most 20 extracts per run, and logs that the rest will follow at later ticks. 20 stays inside the 40-file allowance with room for retries and the operator's own downloads. More than 24 regions is warned about at startup, since a rebuild then can't fit in one day's refill.
- **Requests are sequential**, one at a time, with `User-Agent: overpass-coolify-sidecar` (no contact address).

## Testing

### Unit tests (pytest, no network, no osmium)

Run on the host in under a few seconds.

| Area | Cases | Fixtures |
| -- | -- | -- |
| `state.py` | Parse and format round trip, escaped colons, comments, the planet-minute comment, `seq_path` | Real `state.txt` files from both providers |
| `config.py` | Provider detection, mixed providers rejected, mismatched list lengths, wrong pairing order, trailing slashes, `MERGED_STREAM` mismatch, poll range 1–60 | — |
| Stamp compatibility | The stamp for an existing OSM France configuration is byte-identical to the one `lib.sh` writes | A `regions.txt` written by the bash sidecar |
| `pairing.py` | Normal days, the two two-day diffs (Freiburg 4857, Ontario 4937), the extra planet states, bursts, the offset changing from 14 to 15, a region lagging by days, re-initialisation patterns | The 133 per-sequence state files each for Freiburg, Karlsruhe and Ontario from the test cache |
| `snapshot.recover` | Every combination of `.tmp` directory, complete directory and published head | Synthetic directory trees |
| `stream.prune_plan` | Both providers, guard by `replicate_id` and by snapshot, empty stream | Synthetic file lists |
| `health.py` | Every message `health.sh` prints today, plus the Geofabrik limits and the backlog case | Synthetic `status.txt` and clocks |
| `merge/diffmerge.py` tie-break | The `golden_horseshoe` + `central_ontario` tie at 7351478, a tie involving a v1 create, no-op on Geofabrik diffs (C1), unknown input rejected | Small hand-written `.osc` files |
| Bootstrap decisions | When to build, wait or skip, for both providers; strict versus warn-only `.md5` | Fake `Http` |
| Download budget | Cached extracts reused across failed runs; backoff after a mismatch, truncation or 429; a 429 stops the run; at most 20 extracts per run; no extract downloads in steady state or for a re-import | Fake `Http` with request counts |

### Integration tests (real osmium, in the image)

A `test` target in the Dockerfile adds `python3-pytest` and runs `tests/integration`. They use small synthetic OPL datasets, converted with `osmium cat`, so they run in seconds and need no downloads:

- **The orphan case.** Two regions share a border, and a way in region B uses node `n7`, which lies inside region A. On day 1 the way stops using `n7`. Assert that the old OSM France merge deletes `n7`, and that the snapshot-diff merge keeps it and equals `osmium merge` of the two day-1 extracts. This is the D3 event of 08-24, reduced to a few objects.
- **A two-day diff.** One region's two days combined with the other's two separate diffs give the same result as merging day by day.
- **A real deletion, a move across the border, a create, and a modify** are all carried correctly.
- **`apply(M, derive(M, M')) = M'`** on each fixture.
- **Crash recovery.** Kill the step after each of steps 2–7 (a test hook raises), rerun, and check that the stream and step directories end up identical to an uninterrupted run.

### End-to-end tests

These need Docker and the test cache, so they run by hand or in a scheduled job, not on every commit.

- **OSM France parity.** Before the bash scripts are deleted, record their output for a fixed window: the merged diffs, state files and `status.txt` produced by the current sidecar against a local mirror of a few hundred OSM France minutes. The Python sidecar must produce byte-identical diffs and state files over the same window, apart from `updated=` timestamps.
- **Geofabrik replay.** Serve the cached Freiburg and Karlsruhe `-updates` folders from nginx with their recorded `Last-Modified` times (as in the third test round), and run the full stack over all 96 days from the `260801` extracts. Check weekly that the merged file equals `osmium merge` of the two rolled-forward extracts, and at the end that an Overpass export equals `merge(261106)`. This closes D5's open point: the snapshot-diff merge has so far been checked on one day only, and not through Overpass.
- **F2 failure cases** from `DESIGN.md`: a stalled region, a diff missing below a region's head, a region-list change and back, a database wipe with the snapshot kept, an OOM-killed step, and a Geofabrik-style burst and 36-hour delay (E6).
- **Border queries** with `multi-extract/tools/compare.sh`, rewritten for the Freiburg/Karlsruhe border.

### Tooling

`ruff` and `mypy --strict` on `overpass_sidecar/`, and `shellcheck` on the remaining `entrypoint.sh`, all in the test stage. A GitHub Actions workflow runs the unit tests on every push and the integration tests through `docker build --target test` (amd64 runners, so no emulation).

## Phases

### Phase 0: preparation

- Record in `DESIGN.md` why Geofabrik is a supported source despite `robots.txt` (R0): Geofabrik documents automated updates, and diffs and `state.txt` don't count toward its download limit (see *Requests to Geofabrik*). Link the sources, so the reasoning can be checked again if Geofabrik's policy changes.
- Copy the fixtures into `multi-extract/tests/fixtures/`: the state files from the test cache and a few small diffs. Leave out the extracts.
- Record the OSM France parity baseline with the current bash sidecar.

### Phase 1: Python port with OSM France parity

- Add `python3` to the image (no pip), check the size it adds, and add the package with `config`, `http`, `osmium`, `state`, `stream`, `status`, `health`, `bootstrap`, `catchup`, `init` and `diffmerge`, behaving exactly like the bash scripts. Port `tiebreak.pl` with the same strict line parser, and test it against the Perl version on recorded diffs before deleting it.
- Switch the crontab, the healthcheck and `overpass-init` to Python. Keep `entrypoint.sh` for the root steps only.
- Pass the parity test, then deploy on Coolify over an existing OSM France stack and check that it upgrades without a rebuild (same stamp, no wipe) and keeps following the stream.
- Delete the bash scripts and `tiebreak.pl`, and update `DESIGN.md` to name the Python modules.

### Phase 2: changes needed by both providers

- The provider protocol, with `osmfr.py` holding what phase 1 hard-coded.
- Pruning by timestamp, the generic "advancing" check, the 1–60 minute poll range, and the `MERGED_STREAM` check.
- These change nothing visible for OSM France. The parity test still passes, apart from the expected `status.txt` additions.

### Phase 3: Geofabrik provider

- `geofabrik.py`: URL validation, strict `.md5` on dated files, metadata policy, defaults.
- `pairing.py` with the per-region maps, and the re-initialisation guard.
- `merge/snapshot.py`: step directories, the daily step, recovery and locking.
- Geofabrik bootstrap and the hard-linked snapshot.
- Unit and integration tests for all of the above, written alongside the code.

### Phase 4: validation

- The Geofabrik replay over 96 days, through Overpass.
- The F2 failure cases on the mirror.
- A live deployment on Coolify with `freiburg-regbez` + `karlsruhe-regbez` for at least 7 days. This also gives the request counts and lag that A4 and E4 still lack.
- Optionally, G1 for an Ontario-sized pair, to confirm the sizing figures before recommending larger regions.

### Phase 5: documentation

- `multi-extract/README.md`: a Geofabrik section with example URL lists, `MERGED_STREAM=day`, defaults, expected data age (typically about 20 h when it changes, up to about 74 h, per E4), areas a day behind the base (E7), and queries by user returning nothing (E1).
- `multi-extract/DESIGN.md`: a section on what the design relies on in Geofabrik's data, the snapshot-diff merge and why the tie-break isn't enough (D3, D4), step directories and recovery, and disk sizing (about 2 `E` steady and 4 `E` during a step in `sidecar-work`, on top of the database).
- Upstream issues for `b1tw153/overpass-api`: the polling anchor (E4) and the day-long main loop and retries (E6).

## single-extract changes (documentation only)

From the test plan's *How results map to changes*: document Geofabrik values for `IMPORT_OSM_DATA_SOURCE` and `OVERPASS_DIFF_URL`, keep `OVERPASS_META_MODE=yes`, and document the data age, the areas lag, 100-day retention and sizing (about 3 × the PBF plus 4–6 GB, G1). An optional data-age warning (E6) and resolving the `-latest` redirect for a strict `.md5` check (A7) can follow later. None of this depends on the sidecar work.

## Open questions

- **Stream path.** `/replication/day` with a `MERGED_STREAM` variable is proposed. A single neutral path for both providers would be simpler, but it would change the public URL of existing OSM France deployments.
- **The fallback merge.** D5's stateful tie-break is the tested fallback. This plan doesn't build it. If the snapshot diff fails the 96-day replay, the tie-break reuses the same per-region extracts, so phase 3's state layout still applies.
- **Many or large regions.** A full merge every day grows with the total size of the regions (about 25 s for two Ontario-sized ones, per D5). That's fine for daily steps, but a long backlog over many large regions could take hours. Measure in phase 4 before setting limits in the README.
