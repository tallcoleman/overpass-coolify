# Geofabrik extracts: test plan

Both deployments in this repo serve [OpenStreetMap France](https://download.openstreetmap.fr/) extracts with minutely diffs. This document lays out tests to find what changes, if any, would let [`single-extract/`](../single-extract/) or [`multi-extract/`](../multi-extract/) serve extracts from [Geofabrik](https://download.geofabrik.de/) instead. Each test states the question it answers, how to run it, what we expect, and which decision depends on it. The results go in the *Results* section at the end, and the change list follows from them.

The known difference is that Geofabrik publishes daily diffs, not minutely ones. The reconnaissance below found several more, and some of them matter more for `multi-extract/` than the update frequency does.

## What we know already

Checked on 2026-11-07 with 23 requests to download.geofabrik.de, plus Geofabrik's [technical notes](https://download.geofabrik.de/technical.html). The OSM France column comes from [`multi-extract/DESIGN.md`](../multi-extract/DESIGN.md).

| Property | OSM France | Geofabrik |
| -- | -- | -- |
| Update frequency | Minutely | Daily, from a planet state taken at about 21:20 UTC |
| How diffs are made | Each region's diff is filtered from the planet minute diff | "The difference between the new extract and the previous one". Diffs can also contain changes caused by edits to the clipping polygon |
| Diff URL layout | `.../replication/<path>/<region>/minute/NNN/NNN/NNN.osc.gz` | `.../<path>/<region>-updates/NNN/NNN/NNN.osc.gz`, with `state.txt` at the root of `-updates` |
| Sequence numbers | The planet's minute sequence, shared by every region | A small daily counter that isn't shared across the server. Europe was at 4950 and North America at 4964 for the same day. Each `state.txt` carries a comment: `# original OSM minutely replication sequence number 7361559` |
| Pairing across regions | Diff `N` covers the same minute in every region | Freiburg 4947–4950 and Ontario 4961–4964 cover the same four days (planet minutes 7357315, 7358731, 7360148, 7361559), always 14 apart |
| Publication time | Within minutes, regions a few minutes apart | Hours to more than a day after the data timestamp. Freiburg's diffs for 11-03 to 11-06 appeared between 6 and 30 hours after their data timestamps, and Ontario's diff for a given day appeared 4.4 to 7.6 hours after Freiburg's |
| Bursts | Rare | Common: Freiburg 4949 and 4950 appeared in the same minute, and so did Ontario 4962 and 4963 |
| Diff retention | About 5 weeks | 100 days |
| Extract cut | `osmium extract -s complete_ways` | Cascading `osmium extract` (world → halves → continents → countries → regions). Ways and multipolygon relations that cross a border are kept complete, which suggests `-s smart` |
| Polygons | Region boundaries | Buffered boundaries, "occasionally ... a little more of a neighbouring country", edited from time to time |
| Metadata | Full (version, timestamp, changeset, user, uid) | The public server leaves out `user`, `uid` and `changeset`. Full metadata needs an OSM login on a separate internal server |
| `-latest.osm.pbf` | A file (same as `<region>.osm.pbf`) | A `307` redirect to the dated file, e.g. `freiburg-regbez-261106.osm.pbf` |
| `.md5` | Only for the plain name, sometimes stale | Exists for the dated file. `-latest.osm.pbf.md5` is served from it (`X-Derived-From` header) |
| Older extracts | None | About a week of dated daily files, plus monthly and yearly ones (`ontario-261031.osm.pbf` and so on). Some days are missing: Ontario has no `261104` file, though its diffs have no gap |
| Re-initialisation | Not documented | "Every couple of months we re-initialise our update process with a new planet file" |
| Smallest Canadian region | `golden_horseshoe` (175 MB) and smaller | `ontario` (978 MB). No sub-regions |
| Request policy | At most one `state.txt` request per 5 minutes | `robots.txt` exists (since 2023-11-21) and disallows `*.osm.pbf`, `*.osc.gz`, `state.txt`, `*updates*` and `*.md5` for all user agents. The technical notes still tell users to update with `pyosmium-up-to-date`. No published polling limit was found. (The reconnaissance said `robots.txt` didn't exist. That was wrong, see *Results*, R0) |

Two of these change the multi-extract design, not just its settings:

- **Sequence numbers aren't shared.** The merge can't assume that diff `N` of region A and diff `N` of region B cover the same day. Within one continent they seem to, but across continents they are offset. The planet-minute comment could be used to pair diffs instead.
- **Diffs are differences between extracts.** If an object leaves region A's extract (for example a node outside A's polygon that a way no longer uses) but stays unchanged in region B, A's diff deletes it and B's diff says nothing. A merged stream would then delete a live object. The current tie-break only handles deletes that tie with a create or modify *in another region's diff*, so it can't catch this. How often it happens, and what the deletes look like, decides how the merge has to change (tests C2, D3 and D4).

These are hypotheses until the tests confirm them.

## Ground rules

- **Requests.** No more than one request per second to download.geofabrik.de, and only one request at a time. Use a generic `User-Agent` (e.g. `overpass-coolify-tests`). Check `robots.txt` again before each round of testing, in case one has been added.
- **Download each file once.** Prefer dated file names (`<region>-YYMMDD.osm.pbf`) to `-latest`, so that a download can't change under a test and can be cached. Keep every download in a cache directory, and run the tests against the cache.
- **A local mirror for repeated runs.** Tests that run the sidecar or `overpass` many times (E3–E6, F2) should point at a local nginx mirror of the regions' `-updates` folders, not at Geofabrik. The mirror is filled once and served with the same layout and `Last-Modified` headers, which can then be changed to simulate late or bunched publication.
- **Tools.** Run osmium and the Overpass scripts inside `b1tw153/overpass-api:0.7.62.11-r21`, as the multi-region prototype did, so the tests use the same osmium (1.15.0) and Perl as the deployments.

### Test regions

| Role | Regions | Size (2026-11-06) | Why |
| -- | -- | -- | -- |
| Adjacent pair | `europe/germany/baden-wuerttemberg/freiburg-regbez` + `karlsruhe-regbez` | 160 MB + 155 MB | Adjacent, of similar size to the OSM France Ontario regions used before, with a shared parent |
| Reference parent | `europe/germany/baden-wuerttemberg` | 653 MB | Geofabrik cuts the two regions from this file, so cutting it with their polygons gives an exact reference, as `ontario` did for the OSM France prototype |
| Cross-continent check | `north-america/canada/ontario`, `north-america/canada/quebec` | State files only | Sequence numbering and publication timing, without downloading the extracts |
| Single extract | `freiburg-regbez` | 160 MB | Small enough to import quickly under emulation |
| Sizing (optional) | `north-america/canada/ontario` | 978 MB | The smallest Geofabrik extract covering the Golden Horseshoe |

## Tests

Tests are grouped by what they look at. Groups A–C only read Geofabrik's files and need no Overpass. D is about merging regions. E and F run the deployments.

### A. Server layout and replication metadata

These need only state files and directory listings: a few hundred small requests in all, spread out over time.

**A1. Region index.** Download `index-v1-nogeom.json` once. List every region's `pbf` and `updates` URLs, and check that every region has an `updates` link. *Decides:* whether the configuration can stay as two URL lists, or could take a Geofabrik region id and look its URLs up in the index.

**A2. Sequence numbering across regions.** Read `state.txt` for about 30 regions spread over every continent and depth (continents, countries, sub-regions). Record `sequenceNumber`, `timestamp` and the planet-minute comment. *Expected:* the same planet minute everywhere on a given day, and sequence numbers that are equal within groups (perhaps the "halves" of the cascading split) but offset between them. *Decides:* whether the merged stream can reuse a region's sequence numbers (regions from one group), or has to pair diffs by planet minute and number the merged stream itself (any regions).

**A3. Pairing over time.** For the two test regions and for Ontario, read every per-sequence `state.txt` still on the server (100 days, so about 100 requests per region). Check that each region has exactly one diff per planet state, that the gaps between planet minutes are about a day, and that the offset between groups never changes. Look for any day that one region skips or covers with a two-day diff. *Decides:* whether the barrier can stay "the lowest region head", or has to become "the newest planet minute that every region has as a diff boundary".

**A4. Publication timing.** From the same files, use `Last-Modified` to measure how long after its `timestamp` each diff appeared, how far apart regions publish the same day, and how often two or three diffs appear within the same hour. Repeat the publication-time check for 7 days with an hourly poll of the root `state.txt` of each test region, recording when it changes. *Decides:* the sidecar's poll interval and lag alert, the expected data age (up to two days), and how often the image's frequency detection is at risk (E3).

**A5. Re-initialisation.** In the 100-day history, look for signs of the periodic re-initialisation: a jump or reset in `sequenceNumber`, a planet-minute gap of more than a day, or an unusually large diff in the directory listing. If one is found, download that diff for one test region and check what it contains. *Decides:* whether a re-initialisation breaks a database that follows the diffs, and whether the sidecar has to detect it.

**A6. Retention.** Find the oldest diff in each test region's `-updates` folder. Check it is about 100 days old. Also record how long dated daily extracts are kept, from the directory listing. *Decides:* `stream_cant_resume` timing, and how far back a bootstrap can pick a dated extract.

**A7. Downloads.** Check that `-latest.osm.pbf` always redirects to the newest dated file, how long the redirect is cached (`Cache-Control: max-age=600`), whether `-latest.osm.pbf.md5` always matches the file it redirects to, and what the `.md5` file contains (hash plus dated or `-latest` name). Confirm that `curl -fSL` in `single-extract/scripts/init.sh` and the sidecar's `curl -fsSIL` size check follow the redirect. *Decides:* whether the download and checksum code needs changes. A `.md5` that matches would let both deployments make the check strict for Geofabrik.

### B. Extract contents

**B1. PBF header.** Run `osmium fileinfo` on a dated extract of each test region. Record `osmosis_replication_sequence_number`, `osmosis_replication_timestamp` and `osmosis_replication_base_url`. *Expected:* the sequence number and timestamp of that day's `state.txt`, and the region's `-updates` URL. *Decides:* whether bootstrap can keep reading `S` from the header, and whether init can use the header in place of `bisect_timestamp.sh`.

**B2. Metadata.** Run `osmium fileinfo -e -j` on an extract and check which fields are present on every object. *Expected:* version and timestamp on all objects, and no changeset, uid or user. Check a few diffs for the same fields. *Decides:* whether bootstrap's metadata check needs to accept missing user data (it would warn on every Geofabrik extract as written), and what to test in E1.

**B3. Cut strategy.** Re-cut each test region with its own `.poly` using `simple`, `complete_ways` and `smart`, and compare object counts with the original, as was done for OSM France. *Expected:* the `complete_ways` re-cut loses objects (multipolygon member ways wholly outside the polygon), and the `smart` re-cut doesn't. Count the objects that lie wholly outside the polygon. *Decides:* how to build the reference in D2, and how much the regions overlap.

**B4. Referential integrity.** Run `osmium check-refs -r` on each extract. *Expected:* missing relation members only (members of relations that aren't multipolygons, outside the region), and no missing way nodes. *Decides:* the baseline for later comparisons. Overpass also handles missing members, but this records what is normal.

### C. Diff contents

**C1. Format.** Look at the XML of a few diffs: the `generator`, whether every element start tag is on a line of its own, whether deletes carry tags, node lists and members, and which attributes appear. Run `multi-extract/sidecar/tiebreak.pl` on them. *Decides:* whether `tiebreak.pl`'s strict line parser accepts Geofabrik's diffs or dies (which would stop the stream).

**C2. Deletes.** For a week of diffs for one test region, list each delete's type, id and version. Compare a sample of about 100 with the OSM API history (one request per second to api.openstreetmap.org, following its usage policy). Sort them into real deletions and objects that left the extract. *Expected:* if Geofabrik uses `osmium derive-changes` without `--increment-version`, both kinds carry the object's *old* version and look the same. *Decides:* whether any rule based on versions alone can tell a real deletion from an object leaving one region. If it can't, the multi-extract merge needs state from outside the diffs (D5).

**C3. Roll-forward identity.** Take the oldest kept dated extract of a test region, apply each following diff with `osmium apply-changes`, and compare the result with each later dated extract using `osmium diff`. Include a day with no dated file, if one falls in the window. *Expected:* identical, since the diffs are defined as the difference between extracts. *Decides:* whether a single extract plus its diffs stays correct, and whether the sidecar can roll an older extract forward at bootstrap as it does now.

**C4. Creates and modifies that aren't edits.** In the same week of diffs, count creates with a version above 1 and modifies where the version didn't change. These would be objects entering the extract without being edited (a way gains a node outside the polygon, or the polygon grows). *Decides:* whether Overpass's `update_database` handles them (checked in E5), and how often the merged stream sees objects move between regions without an edit.

### D. Adjacent regions (multi-extract)

Run on `freiburg-regbez` + `karlsruhe-regbez`, with `baden-wuerttemberg` as the reference, over at least 5 consecutive days so that both weekend and weekday edits are included.

**D1. Overlap.** Find the objects that appear in both extracts on the same day. Check that every shared object has the same version in both, and count them. *Expected:* same versions, since both regions are cut from one planet state. *Decides:* whether `osmium merge` still de-duplicates correctly.

**D2. Merged snapshot vs reference.** Merge the two regions' extracts for day `D0` with `osmium merge`. Build the reference by cutting `baden-wuerttemberg` for `D0` with each region's polygon, using the strategy from B3, and merging the two cuts. Compare with `osmium diff`. *Expected:* identical. *Decides:* whether the bootstrap snapshot needs any change.

**D3. Deletes that a merge gets wrong.** For each day, classify every delete in each region's diff:

| Class | Meaning | Current sidecar |
| -- | -- | -- |
| Tied | The other region's diff has the same object at the same version as a create or modify | Dropped by `tiebreak.pl`, correct |
| Superseded | The other region's diff has a higher version | Kept, and `--simplify` keeps the higher version, correct |
| Orphan | The other region's diff doesn't mention the object, but the other region's extract still has it after that day | Kept, and the merge deletes a live object. Wrong |
| Genuine | Neither region has the object after that day | Kept, correct |

*Expected:* orphans exist, most often for nodes and member ways near the border. *Decides:* how serious the problem is. Any orphans at all mean the current merge can't be used as it is.

**D4. Current merge on Geofabrik data.** Run the existing merge (tie-break, then `osmium merge-changes --simplify`) on each day's region diffs, in both input orders. Apply the merged diffs to the `D0` snapshot and compare with the `Dn` reference from D2. *Expected:* missing objects matching D3's orphan count. *Decides:* confirms D3 with the code that would actually run.

**D5. Alternative merges.** Try two replacements and compare each with the `Dn` reference:

- **Merged snapshots, then a diff of those.** Keep each region's extract in the sidecar and roll it forward with its own daily diff (C3 says this reproduces Geofabrik's next extract). Merge the regions' rolled-forward extracts, and make the merged diff with `osmium derive-changes` between yesterday's and today's merged files. Measure time, peak memory and disk for two regions and for an Ontario-sized region. Daily updates make this affordable where it wasn't for minutely ones.
- **A stateful tie-break.** Keep an index of which object ids each region holds (from its extract, updated with each diff). Drop a region's delete when another region still holds the object after that day. Measure the index's size and the time to update it.

In both cases, apply the merged diffs in a real Overpass database (E5) and compare the result with an import of the `Dn` reference. *Decides:* which merge design `multi-extract/` would use for Geofabrik.

**D6. Regions from different groups.** If A2 shows that sequence numbers differ by group, check (from state files only) that a European and a North American region still pair one-to-one by planet minute every day. Merge their diffs only if a real use case needs regions from two groups. *Decides:* whether the merged stream needs its own numbering, or can reuse one region's numbers when all regions come from one group.

### E. Overpass image behaviour (single extract)

Run with `single-extract/` pointed at `freiburg-regbez` and its `-updates` folder. Use the local mirror for every case except E4.

**E1. Import without user data.** Import a Geofabrik extract with `OVERPASS_META_MODE=yes`. Check that the import succeeds, what `out meta;` returns for `user`, `uid` and `changeset`, and what `user(...)`, `uid(...)` and `changed` filters do. Compare database size and import time with `OVERPASS_META_MODE=no`. *Decides:* whether to keep meta mode for Geofabrik (version and timestamp are still useful) or switch to data-only, and what to tell users about queries by user.

**E2. Starting point.** Let `init.sh` run `bisect_timestamp.sh` against the `-updates` URL, and compare the `replicate_id` it writes with the header's `osmosis_replication_sequence_number` from B1. Repeat with a dated extract that is a few days old. *Expected:* equal, if the extract timestamp equals the state timestamp exactly. An off-by-one here would skip or repeat a day. *Decides:* whether `init.sh` can keep bisecting, or should read the header for Geofabrik.

**E3. Frequency detection.** Start `overpass` against the live `-updates` URL once and check that it logs `Detected update frequency: 86400s`. Then, on the mirror, set the `Last-Modified` of the three newest state files to reproduce the patterns A4 found: normal days, two diffs in one minute, three diffs within an hour. The image averages the gaps between files `N`, `N-1` and `N-2`. Under 30 minutes it detects minutely updates and under 12 hours hourly ones, so a three-diff burst should be detected as minutely. Record what `fetch_osc.sh` then does: its poll interval, whether it rejects the stream, and what `OVERPASS_CLEANUP_KEEP_HOURS` turns into. *Decides:* whether single-extract can follow Geofabrik directly, or needs something in between that publishes state files with steady `Last-Modified` times (the multi-extract sidecar already does this with each file's `timestamp`).

**E4. Polling against Geofabrik.** Run `overpass` against the live `-updates` URL for 7 days. Count its requests to Geofabrik per day (from `fetch_osc.log`, or through a logging proxy), and record the lag between Geofabrik publishing a diff and the database applying it. Publication times vary by many hours, so expect `fetch_osc.sh` to fall back to its 20-minute polls (`PHASE3_DELAY=1200`) on most days. *Decides:* whether the request rate is reasonable (about 3 per hour at worst), and the lag users should expect.

**E5. Applying a daily diff.** Time `apply_osc_to_db.sh` on the largest daily diff in the test week, measure its peak memory, and check that its log shows no errors for the creates with old versions and the deletes found in C2 and C4. Do the same for Ontario's largest daily diff if the sizing test is run. *Decides:* whether `stop_grace_period: 120s` is still long enough (an update must finish before the container stops), and the memory needed during updates.

**E6. Health during late publishing.** On the mirror, hold back a diff for 36 hours, then publish two at once. Check the `overpass` healthcheck, the image's own stall detection (`OVERPASS_STALL_MULTIPLIER` times the detected frequency) and what Coolify would show. *Decides:* whether the healthcheck or the stall settings need changing for daily updates.

**E7. Areas and cleanup.** With `OVERPASS_AREAS=yes`, check that area updates follow the daily diffs, and that diff cleanup keeps the expected number of files (72 hours at 86400 s is 3 diffs). *Decides:* whether either setting needs a different default for daily updates.

### F. Multi-extract sidecar

**F1. Minute assumptions in the code.** List every place that assumes minutely diffs or OSM France's layout, and decide what each one becomes for Geofabrik. Known places so far:

| Place | Assumption |
| -- | -- |
| `lib.sh` stamp normalisation, `ROOT_STATE`, `$REPL/minute` | Diff URLs end in `/minute`, and the merged stream is served at `/replication/minute` |
| `entrypoint.sh` | Polling below 5 minutes warns, quoting OSM France's limit |
| `health.sh` | The head is "advancing" if its diff is less than 5 minutes old. `MERGE_LAG_ALERT_MINUTES` defaults to 30 |
| `catch-up.sh` | Barrier = lowest region head, by sequence number (A2, A3) |
| `bootstrap.sh` | Warns when objects lack full metadata (B2). Rolls forward with region diffs (C3). Seeds `S-2`, `S-1` and `S`, which with daily diffs means state files for two days that are already old |
| `status.txt` | `merge_lag_minutes` and `overpass_lag_minutes` are counted in minutes or sequence steps |
| `tiebreak.pl` | Line-based parser for OSM France's `xmlwriter` output (C1) |
| Pruning | Merged diffs are kept by hours, which assumes about 60 diffs per hour |

*Decides:* the list of code changes, apart from the merge itself (D5).

**F2. End to end.** Once D5 has picked a merge design and F1's changes are made, run the stack on the mirror with the two test regions for 7 simulated days, published with the timing patterns from A4. Then compare with an Overpass import of the reference, using `multi-extract/tools/compare.sh` for border queries and `osmium diff` on an export. Repeat the failure cases from `DESIGN.md` that depend on timing: a stalled region, a diff missing below a region's head, and a region-list change. *Decides:* whether the Geofabrik variant is ready to deploy.

### G. Sizing

**G1. Database size and import cost.** Record the PBF size, database size, import time and peak memory for `freiburg-regbez`, and for the merged pair. If Ontario matters, do the same for `ontario` (978 MB), which at the 14–20× ratio seen with OSM France would need about 14–20 GB of database. Note how much bigger a `smart` cut is than OSM France's `complete_ways` cut of a similar area. *Decides:* the sizing guidance in each README.

## Request budget

| Group | Requests to Geofabrik | Data |
| -- | -- | -- |
| A | About 500 state files and listings, spread over a week | Under 1 MB |
| B, C | 3 dated extracts per region for the window, 7 diffs per region, `.poly` files | About 1 GB |
| D | The `baden-wuerttemberg` extract for `D0` and `Dn` | About 1.3 GB |
| E4 | `overpass` polling for 7 days | About 70 requests per day at most |
| Everything else | None (local mirror) | |

At one request per second, group A takes under 10 minutes of requests in total. The extract downloads are the main load, and each one is made once.

## How results map to changes

What each deployment would probably need, assuming the tests confirm the hypotheses above. This list gets corrected as results come in.

Updated 2026-11-07 with the results below. Items marked (open) still depend on tests not yet run.

**Both deployments**

- `robots.txt` disallows every file the deployments fetch (R0). Treated here as aimed at crawlers, since Geofabrik documents automated updates. Worth confirming with Geofabrik before publishing Geofabrik as a supported source.

**`single-extract/`**

- New documented values for `IMPORT_OSM_DATA_SOURCE` (`.../<region>-latest.osm.pbf`) and `OVERPASS_DIFF_URL` (`.../<region>-updates`) (A1).
- No change to downloads or checksums: the redirect is followed and the `-latest` `.md5` is a direct `200` (A7). To make the check strict, resolve the redirect once and fetch the dated file and its dated `.md5`, which also removes the 10-minute cache race.
- A decision on meta mode without user data, documented (B2; E1 open).
- The starting sequence can come from the PBF header (B1). Whether `bisect_timestamp.sh` agrees is open (E2).
- No relay needed. A burst can make the image detect hourly updates after a restart, which costs extra polling and diff retention but not correctness, and bursts happen about once a month (A4, E3 desk check). The mirror run is open.
- Documentation: data typically 6–20 h old when it appears and up to about 64 h old just before the next diff, 100-day diff retention (131 observed), larger regions, and about 30 polls a day plus 3 an hour on late days (A4, A6, E4 desk check; G1 open).

**`multi-extract/`**

- Pair region diffs by planet minute, not sequence number, and number the merged stream itself (A2, A3). Sequence numbers differ between almost all regions, and the offset between two regions changes whenever one of them skips a day. The barrier becomes the newest planet minute every region has reached, and a day that one region covers with a two-day diff is merged as one step.
- A different delete tie-break (D3/D4 over 96 days). The current merge lost 80 live nodes in 5 events over 96 days for the test pair: orphan deletes caused by border-crossing ways that stopped using a node. These were the only differences. The fix is to keep each region's extract rolled forward with its own diff (exact, C3) and drop a region's delete when another region's extract still has the object and that region's diff doesn't mention it. Measured cost: a few seconds per region per day, and one extract per region on disk. The existing `tiebreak.pl` is a no-op for Geofabrik (C1) and can be replaced by this check.
- Health: `MERGE_LAG_ALERT_MINUTES` has to become about 72 hours, and the "advancing" check has to stop assuming 5 minutes (A4, F1).
- Pruning: count by the stream's frequency or by age, not `KEEP_HOURS × 60` sequences (F1).
- Bootstrap: accept version-and-timestamp metadata (B2). Rolling forward is exact (C3).
- Poll interval: 30–60 minutes is plenty, and allowing 60 needs the range check changed (A4, F1).
- `status.txt` wording (minutes versus days), and optionally `/replication/day` (F1).

**Not covered here.** Mixing Geofabrik extracts with OSM France diffs (each provider's diffs match only its own extracts), Geofabrik's internal server with full metadata (it needs an OSM login that the stack would have to renew), and attic mode.

## Results

Record each test's date, the files and sequence numbers it used, and its outcome here, under its ID.

**Status (2026-11-07).** Done: R0, A1–A3, A5–A7, B1–B4, C1, C3, C4, D1, D3, D4 (5 and 96 days), F1. Partly done: A4 (the 7-day hourly poll hasn't been run), C2 (one region, a sample of 100), E3 and E4 (desk check of the image's code only). Not run: D5 (the fix the 96-day run points to still needs to be built and tested), D6 (covered in substance by A2 and A3), E1, E2, E5–E7, F2, G1. Test cache, scripts and request log: `~/.cache/geofabrik-tests/` on the machine that ran them (663 requests to Geofabrik, about 2.4 GB, and 100 to the OSM API; the cache is 7 GB).

Main findings so far:

1. Geofabrik's `robots.txt` disallows the files both deployments fetch (R0).
2. Sequence numbers aren't shared between regions, and the offset between two regions changes when one skips a day, so multi-extract has to pair diffs by planet minute (A2, A3).
3. The current multi-extract merge loses live nodes when a border-crossing way stops using a node: 80 nodes in 96 days for one pair of regions. A check against the other regions' rolled-forward extracts fixes it, and everything else in the merge was exact (D3, D4).
4. Single extracts roll forward exactly (C3), and the image follows Geofabrik's daily diffs without changes, with some extra polling after a burst (E3, E4 desk check).

### R0. `robots.txt` check (2026-11-07)

`https://download.geofabrik.de/robots.txt` returns `200` with `Last-Modified: Tue, 21 Nov 2023 21:54:53 GMT`, so it has been there for three years:

```
User-agent: *
Disallow: *.osm.pbf
Disallow: *.osm.bz2
Disallow: *.osc.gz
Disallow: *.shp.zip
Disallow: state.txt
Disallow: *.state.txt
Disallow: *updates*
Disallow: *.md5
```

This disallows every file the deployments themselves fetch (extracts, `.md5`, `state.txt`, diffs), and most of what groups A–E need. The [technical notes](https://download.geofabrik.de/technical.html) say the diffs follow "the convention used by automatic update tools like Osmosis or pyosmium-up-to-date" and suggest running `pyosmium-up-to-date`, so the rules most likely target crawlers rather than update clients. That is an inference, not something Geofabrik states. Until it is settled, testing kept to paths `robots.txt` allows: the region index, folder listings, `.poly` files and the technical notes (11 requests in all). Not yet run for that reason: A2–A5, A6 (diff part), A7, B, C, D, E1, E2, E4–E7, F2 and G.

### A1. Region index (2026-11-07)

`index-v1-nogeom.json`, 554 regions.

- Every region has `pbf`, `updates`, `pbf-internal`, `history` and `taginfo`. 525 also have `shp`.
- With no exceptions, `pbf` ends in `-latest.osm.pbf` and `updates` is the same URL with `-latest.osm.pbf` replaced by `-updates`.
- Ids are unique. 501 are the last path segment (`freiburg-regbez`), and 53 contain a `/` (for example the US states), with the id's last part still equal to the last path segment.
- Path depth: 9 at the root (continents), 213 at depth 1, 258 at depth 2, 74 at depth 3.

*Outcome:* both URL lists can be derived from a region id, but nothing requires it: a single base URL per region (`.../<path>/<region>`) gives both `-latest.osm.pbf` and `-updates`. Keeping two URL lists stays the simplest change and is no worse than taking an id.

### A6. Retention of dated extracts (2026-11-07, partial)

From the folder listings of `europe/germany/baden-wuerttemberg/`, `europe/germany/` and `north-america/canada/` (listing times are server local time):

| Kind | Kept | Example |
| -- | -- | -- |
| Daily | About a week: `261101`–`261106` | `freiburg-regbez-261106.osm.pbf`, written 2026-11-07 03:30 |
| Month ends | August, September and October 2026 (`260801`, `260901`, `261001`, `261031`) | |
| Yearly | Every 1 January back to 2014 (`.osm.pbf`), with `.md5` only from 2026 | `freiburg-regbez-140101.osm.pbf` |

- Every dated `.osm.pbf` from 2026 has a matching `.md5` (56–68 bytes, so a hash plus a file name).
- **Each group skips a different day.** The German files (Freiburg, Karlsruhe, Baden-Württemberg) have `261104` and `261106` but no `261105`. Ontario and Quebec have `261105` but no `261104`. The reconnaissance found that Ontario's diffs have no gap there, so a missing dated file doesn't mean a missing diff. Possibly the dated file is only written when the next day's run hasn't already replaced it; C3 should include the German `261104`→`261106` step.
- Within a day, parents are written a few minutes before their children (Baden-Württemberg 03:25, Karlsruhe 03:29, Freiburg 03:30 on 2026-11-07), as the cascading split predicts. The Canadian files appeared about 2.5–3 hours after the German ones.
- Day files lag their date by a lot: `freiburg-regbez-261106` was written at 03:30 on 11-07, and `261103` at 16:37 on 11-04.

Diff retention: see the second A6 entry below (131 days).

*Outcome:* a bootstrap can pick a dated extract up to about 6 days old, or a month-end one up to about 3 months old. A month-end file is still within the 100-day diff retention, so rolling one forward by up to ~100 daily diffs is possible in principle (C3 decides whether it's correct).

### E3, E4. Frequency detection and polling, from the image's code (2026-11-07, desk check)

Read from `/opt/overpass/bin/run_osm3s.sh` and `fetch_osc.sh` in `b1tw153/overpass-api:0.7.62.11-r21` (only published for `linux/amd64`, so it runs under emulation on Apple silicon). The live runs are still to do.

**Detection.** `detect_update_frequency` reads the root `state.txt`, then the `Last-Modified` of the per-sequence state files `N`, `N-1` and `N-2` (`curl -sIL`, so redirects are followed). The mean of the two gaps below 1800 s means 60, below 43200 s means 3600, and anything else 86400. It runs once, at container start.

| Last three Geofabrik publications | Mean gap | Detected |
| -- | -- | -- |
| Normal days, about 24 h apart | ~86400 s | 86400 |
| `N` and `N-1` in the same minute, `N-2` exactly a day earlier | 43200 s | 86400 (just) |
| `N` and `N-1` in the same minute, `N-2` less than 24 h earlier | < 43200 s | **3600** |
| Three in one hour | < 1800 s | **60** |

A two-diff burst then puts the detection on a knife edge, and the reconnaissance saw two such bursts in four days. So a restart shortly after a burst will often detect hourly updates.

**Polling.** `fetch_osc.sh` sleeps until `anchor + frequency − frequency/24`, where the anchor is the root `state.txt`'s `Last-Modified`, or the time it first saw the newest file. Then it polls `state.txt` on a back-off schedule, and after that every 1200 s (`PHASE3_DELAY`):

| Detected | Polling starts | Back-off | Then |
| -- | -- | -- | -- |
| 86400 | 1 h before anchor + 24 h | 30 requests over 2.65 h (mostly every 288 s) | every 20 min |
| 3600 | 150 s before anchor + 1 h | 38 requests over 57 min (mostly every 12 s) | every 20 min |
| 60 | 3 s before anchor + 60 s | 24 requests over 49 min, the first 6 with no delay | every 20 min |

Each batch is limited to `86400 / frequency` files and 360 files.

- **Correctly detected (86400).** About 30 requests in the 2.65 h after the expected time, then 3 an hour until the diff appears. Publication drifts by many hours, so on a late day that adds up to about 30 + 3 × 20 ≈ 90 requests. The plan's estimate of "about 70 per day" is a little low. After a burst, the anchor is the burst's time, so the next diff isn't looked for until about 23 h later, even if Geofabrik publishes it after only a few hours. That makes lag of up to about a day possible on top of Geofabrik's own delay.
- **Wrongly detected (3600 or 60).** Updates still work: the loop fetches whatever the root `state.txt` says is new, whatever the frequency. The costs are 24–38 extra requests after each new diff, and `CLEANUP_KEEP_COUNT = KEEP_HOURS × 3600 / frequency` keeps 72 diffs (3600) or 4320 (60) instead of 3. Nothing rejects the stream.
- **Stall detection** is off unless `OVERPASS_STALL_MULTIPLIER` is set, and neither compose file sets it.

*Outcome so far:* single-extract can follow Geofabrik directly. Misdetection costs requests and disk, not correctness. A relay that republishes state files with steady `Last-Modified` times would fix the detection and the post-burst lag, but it's an optimisation, not a requirement. E3's mirror run should confirm this, and E4 should measure the real request count and lag.

### F1. Minute and OSM France assumptions in the code (2026-11-07)

Every place in `multi-extract/sidecar/`, `single-extract/scripts/init.sh` and the compose files that assumes minutely diffs or OSM France's layout, and what it would become for Geofabrik. Places not in the plan's table are marked *new*.

| Place | Assumption | For Geofabrik |
| -- | -- | -- |
| `lib.sh:18`, `bootstrap.sh:155`, `catch-up.sh:85,132`, `health.sh:23`, compose `OVERPASS_DIFF_URL=.../replication/minute` | Merged stream lives under `/replication/minute` | Cosmetic. Works as is, but `/replication/day` (or a neutral name) avoids confusion. Changing it changes the URL the `overpass` service uses |
| `lib.sh:32–36` | Trailing slashes are stripped because OSM France's "copy link" adds one | Harmless |
| `lib.sh:49` `region_name` | Strips `-latest` and `.osm.pbf` | Works for Geofabrik's `-latest` URLs. A dated URL would give `freiburg-regbez-261106` as the name |
| `entrypoint.sh:20–21` | `POLL_INTERVAL_MINUTES` 1–59, warns below 5, quoting OSM France | With daily diffs a 5-minute tick means 288 `state.txt` requests per region per day. Something like 30–60 minutes is plenty; allowing 60+ means changing the cron range check |
| `health.sh:18–24`, `MERGE_LAG_ALERT_MINUTES=30` | Merged head under 30 min old; "advancing" means the head diff is under 5 min old | **Always unhealthy.** Geofabrik's data is 6–54 h old when it appears. Needs a limit in hours (about 54–60 h) |
| `catch-up.sh:31` barrier | Min of region heads by sequence number | Fine within one numbering group. Across groups needs pairing by planet minute (A2, A3) |
| `catch-up.sh:72`, `bootstrap.sh:133,159` | Per-sequence state comes from region 0 | Fine within one group |
| `catch-up.sh:62–69` | A 404 below a region's head is a pruned diff | Fine. Geofabrik's 100-day retention gives far more slack than OSM France's ~5 weeks |
| `catch-up.sh:127` pruning, *new* | `limit = head − KEEP_HOURS × 60`, i.e. 60 diffs per hour | **Never prunes.** 72 h × 60 = 4320 sequences, about 12 years of daily diffs. Harmless for disk (daily diffs are small), but `OVERPASS_CLEANUP_KEEP_HOURS` stops meaning hours. Should count by the stream's frequency, or by file mtime |
| `lib.sh:108–119` `publish_seq_state` | Sets each state file's mtime to its `timestamp`, so `Last-Modified` is 60 s apart | **Works in Geofabrik's favour.** Timestamps are a day apart, so the `overpass` service always detects 86400, even after a burst. This is the relay that E3 discusses, already built |
| `lib.sh:172–174` `status.txt`, *new* | `merge_lag_minutes`, and `overpass_lag_minutes = head − rid` (sequence steps) | `merge_lag_minutes` stays correct but reads as thousands. `overpass_lag_minutes` is really days |
| `bootstrap.sh:81`, *new* | Reuses a download less than 1440 min old | Fine. Possibly reuse a newer dated file instead |
| `bootstrap.sh:67`, `fetch` | `curl -fsSIL`, `curl -fsSL` | Both follow the `307` from `-latest` (`-L`). `tail -n 1` takes the final `Content-Length`. Confirm in A7 |
| `bootstrap.sh:86–94`, `lib.sh:84` `http_code`, *new* | `.md5` is warn-only. `http_code` sends `-I` **without** `-L` | If `-latest.osm.pbf.md5` is a redirect rather than a `200`, `http_code` returns `307` and the check is skipped with "no .md5 (HTTP 307)". The reconnaissance suggests it is served directly (`X-Derived-From`), so probably fine; A7 decides |
| `bootstrap.sh:96–106` | Expects full metadata, warns otherwise | Warns on every Geofabrik extract (no `user`, `uid`, `changeset`, B2). Accept `version,timestamp` as normal |
| `bootstrap.sh:110–130` | `S = max(s_i)`, roll forward by sequence numbers; log says "minutes" | Fine within one group. Log text only |
| `bootstrap.sh:158–161` | Seeds state for `S−2`, `S−1`, `S` | Fine. With daily diffs these are two and one days before `S`, and their mtimes give 86400 |
| `tiebreak.pl` | Line parser for OSM France's `xmlwriter` output; dies on anything else | Unknown until C1. Whatever replaces the merge (D5) may not need it |
| Compose healthchecks | `overpass` and `sidecar` healthchecks every 30 s / 1 min | Not frequency-dependent apart from `health.sh` |
| `single-extract/scripts/init.sh:19–20`, `b1tw153.yml:14`, *new* | OSM France Golden Horseshoe defaults; comments about stale OSM France `.md5` | Document Geofabrik values. `curl -fSL` follows the redirect. The `.md5` fetch uses `-sSL` and `$IMPORT_OSM_DATA_SOURCE.md5`, which for Geofabrik is `-latest.osm.pbf.md5` |

*Outcome:* apart from the merge itself, three changes are needed for multi-extract to work on Geofabrik: the health limit (in hours), the pruning rule (by frequency or by age), and the bootstrap metadata check. The rest is wording, defaults and polling interval. The sidecar's `Last-Modified` handling already protects the `overpass` service from Geofabrik's bursts.

### A2. Sequence numbering across regions (2026-11-07)

Root `state.txt` of 30 regions, fetched 16:13–16:14 UTC:

| Region | Depth | `sequenceNumber` | Planet minute | `Last-Modified` (UTC, 11-07) |
| -- | -- | -- | -- | -- |
| africa, asia, europe, north-america, australia-oceania | 0 | 4966 | 7361559 | 06:56–14:46 |
| antarctica, central-america, south-america | 0 | 4967 | 7361559 | 06:56–16:14 |
| russia | 0 | 4001 | 7361559 | 14:34 |
| germany, france | 1 | 4960 | **7360148** (11-05) | 00:17 |
| canada | 1 | 4965 | 7361559 | 04:49 |
| us | 1 | 2435 | 7361559 | 04:49 |
| japan | 1 | 4962 | 7361559 | 15:56 |
| brazil | 1 | 4965 | **7360148** (11-05) | 11-06 18:35 |
| nigeria / india / australia / mexico / italy | 1 | 4955 / 4959 / 4962 / 4964 / 4961 | 7361559 | 00:16–15:46 |
| baden-wuerttemberg, bayern | 2 | 4956, 4957 | 7361559 | 02:49 |
| ile-de-france | 2 | 4960 | 7361559 | 01:00 |
| ontario, quebec | 2 | 4964 | 7361559 | 06:55 |
| us/california | 2 | 4963 | 7361559 | 04:43 |
| kanto | 2 | 3480 | 7361559 | 15:45 |
| freiburg-regbez, karlsruhe-regbez | 3 | 4950 | 7361559 | 02:31 |
| oberbayern | 3 | 4948 | 7361559 | 02:49 |

- Every state file has the `# original OSM minutely replication sequence number` comment, and all 30 have the same planet minute and `timestamp` (`2026-11-06T21:21:21Z`) except three that are a day behind.
- **There are no numbering groups.** Each region has its own counter, apparently started when the region was added: siblings created together share a number (Freiburg and Karlsruhe, Ontario and Quebec), but a parent and its children don't (Baden-Württemberg 4956, its districts 4950; Bayern 4957, Oberbayern 4948).
- **Parents can be behind their children.** Germany and France were still at 11-05 while Baden-Württemberg, Freiburg and Île-de-France were at 11-06. So the root `state.txt` of a parent isn't a guide to when its children publish, and the hierarchy doesn't order publication.

*Outcome:* the hypothesis was too optimistic. The merged stream can't reuse a region's sequence numbers in general. It has to pair diffs by planet minute and number itself, unless every region is a set of siblings created together, which A3 shows isn't enough either.

### A3. Pairing over time (2026-11-07)

All 133 per-sequence state files of Freiburg (4818–4950), Karlsruhe (4818–4950) and Ontario (4832–4964), covering 2026-06-29 to 2026-11-06.

- Sequence numbers are contiguous in every region, each state file has a planet-minute comment, and the planet minute always increases.
- Freiburg and Karlsruhe are identical: same sequence numbers, planet minutes and timestamps every day, and `Last-Modified` within 2 minutes of each other.
- For a given planet minute, `timestamp` is the same in every region (132 shared planet minutes, no mismatch).
- **Two-day diffs.** Each region skipped one planet state and published one diff covering two days, but on different dates: Freiburg and Karlsruhe 4857 covers 08-03 → 08-05 (Ontario has 08-04 as 4871), and Ontario 4937 covers 10-08 → 10-10 (the German regions have 10-09 as 4922). So **the offset between Ontario and Freiburg is 14 for 67 days and 15 for 65**. It changes whenever one region skips a day.
- **Extra planet states.** On 07-03 (04:51 UTC) and 07-28 (04:41 UTC) every region got an extra diff a few hours after the normal 20:21 one. All regions have them, so they don't break pairing, but they give two diffs in one day.
- Data timestamps follow local time: about 20:21 UTC in summer, 21:21 UTC since the end of October.

| Gap between consecutive diffs | Count (each region) |
| -- | -- |
| About 24 h | 127 |
| 8–9 h, then 15–16 h (extra state) | 2 days |
| 48 h (skipped day) | 1 |

*Outcome:* the barrier can't stay "the lowest region head by sequence number". It has to be the newest planet minute that every region has reached. A day that one region skipped has to be merged as one step: the merged diff for planet minutes `P1 → P3` combines region A's single diff with region B's two diffs `P1 → P2` and `P2 → P3`. Otherwise region A's two-day diff would be merged with region B's one-day diff. So the merged stream needs its own numbering, and catch-up needs, for each region, a map from planet minute to sequence number, built from the per-sequence state files (one request per region per diff).

### A4. Publication timing (2026-11-07, from the 133-day history; the 7-day hourly poll hasn't been run)

`Last-Modified` of each per-sequence state file minus its `timestamp`:

| Region | Min | Median | 90th percentile | Max |
| -- | -- | -- | -- | -- |
| Freiburg, Karlsruhe | 2.8 h | 6.2 h | 19.5 h | 39.2 h |
| Ontario | 2.5 h | 4.4 h | 19.6 h | 40.0 h |

- **Bursts** (two diffs published less than an hour apart): 2 in 133 days for Freiburg and Karlsruhe (4884–4885, 4949–4950), 4 for Ontario (4899–4900, 4933–4934, 4948–4949, 4962–4963), all within a minute. No three-diff bursts. That's about one burst a month, not "common" as the reconnaissance's four-day sample suggested.
- **Across continents:** Ontario minus Freiburg ranges from −32.7 h to +7.6 h (median +0.5 h). Ontario published first on 52 of 132 days, so neither region reliably leads.
- Within Baden-Württemberg, Karlsruhe and Freiburg publish within −1.7 to +0.4 minutes of each other.

*Outcome:* a merged head built from the slowest region will typically be 6–20 hours behind its data timestamp, and up to about 40 hours behind on a bad day. The data in the database is then up to about 64 h old just before the next diff (40 h of delay plus a day). A health limit of about 72 hours would avoid false alarms. A poll interval of 30–60 minutes costs nothing in lag that matters. Image frequency detection: with bursts about monthly and never three at once, misdetection (E3) is a rare, harmless case.

### A5. Re-initialisation (2026-11-07, partial)

No sign of a re-initialisation in 133 days: no sequence reset or jump, no planet-minute decrease, and no planet-minute gap over 48 h. The only irregularities are the two extra planet states (07-03, 07-28) and the two skipped days (A3). The extra states are the best candidates, since an extra run is what a re-initialisation would look like from outside. Their diffs aren't unusually large, though: Freiburg 4823 and 4849 are normal sizes.

The largest diffs (from the folder listings) are:

| Region | Median | Largest |
| -- | -- | -- |
| Freiburg | 392 KB | 4889 (09-07) 1.2 MB, 4919 (10-07) 1.0 MB |
| Karlsruhe | 451 KB | 4919 (10-07) 1.8 MB, 4889 (09-07) 1.6 MB |
| Ontario | 432 KB | 4918 (09-21) 34 MB, 4924 (09-27) 32 MB, 4916 (09-19) 31 MB, and others of 20–25 MB in September |

Freiburg and Karlsruhe peak on the same two days, and Ontario's September series looks like an import in progress. Telling edits from re-initialisation or polygon changes needs the diffs' contents (C2, C4).

### A6. Retention of diffs (2026-11-07)

Each test region's `-updates/000/004/` folder holds 133 diffs and 133 state files, the oldest from 2026-06-29 (Freiburg and Karlsruhe 4818, Ontario 4832). That's **131 days**, more than the 100 the technical notes promise. Plan for 100.

### A7. Downloads (2026-11-07)

- `freiburg-regbez-latest.osm.pbf` returns `307 Temporary Redirect` to `freiburg-regbez-261106.osm.pbf`, with `Cache-Control: max-age=600, public`.
- `freiburg-regbez-latest.osm.pbf.md5` returns **`200` directly** (no redirect), `X-Derived-From: .../freiburg-regbez-261106.osm.pbf.md5`, `max-age=600`, with content `2ec81cd6ebeb7710d5802a9d4991d4e7  freiburg-regbez-latest.osm.pbf`. The hash is the dated file's, and the name is rewritten to `-latest`.
- The dated `.md5` files have `max-age=63072000` (two years) and name the dated file.
- The redirect and the `.md5` are cached separately, each for up to 10 minutes. A download that starts just before a new extract appears can pair the old file with the new `.md5`.

*Outcome:* the code needs no changes. `http_code` without `-L` gets the `200`, both scripts compare hashes rather than names, and `curl -L` follows the redirect. To make the check strict, resolve the redirect once (`curl -w '%{url_effective}'`), then download the dated file and its dated `.md5`. That removes the race and gives a file name that can't change under a retry.

### Files used from here on (downloaded 2026-11-07)

| Region | Dated extracts (sequence) | Diffs |
| -- | -- | -- |
| freiburg-regbez | `261101` (4945), `261104` (4948), `261106` (4950) | 4946–4950 |
| karlsruhe-regbez | `261101`, `261104`, `261106` (same sequences) | 4946–4950 |
| baden-wuerttemberg | `261101`, `261106` | none |

Every extract matched its dated `.md5`. Tools: osmium 1.15.0 and Perl in `b1tw153/overpass-api:0.7.62.11-r21` (amd64, emulated).

### B1. PBF header (2026-11-07)

`freiburg-regbez-261101` and `-261104`:

```
generator=osmium/1.16.0
osmosis_replication_base_url=https://download.geofabrik.de/europe/germany/baden-wuerttemberg/freiburg-regbez-updates
osmosis_replication_sequence_number=4945   (261104: 4948; 261106: 4950)
osmosis_replication_timestamp=2026-11-01T21:21:36Z
timestamp=2026-11-01T21:21:36Z
sorting=Type_then_ID
```

*Outcome:* as expected. The sequence number and timestamp equal that day's per-sequence `state.txt` exactly, and the base URL is the region's `-updates` folder. Bootstrap can keep reading `S` from the header, and `init.sh` could read it instead of bisecting (E2 checks whether bisecting gives the same answer). A dated file's name (`YYMMDD`) is the date of its data timestamp.

### B2. Metadata (2026-11-07)

`osmium fileinfo -e -j` on Freiburg `261101` and `261104`: `all_objects` and `some_objects` are both `version: true, timestamp: true, changeset: false, user: false, uid: false`. The diffs have the same attributes: `id`, `version`, `timestamp`, and `lat`/`lon` for nodes.

*Outcome:* as expected. `bootstrap.sh`'s metadata check would warn on every Geofabrik extract: `not every object has full metadata: "version":true,"timestamp":true,"changeset":false,"user":false,"uid":false`. It should treat version-and-timestamp as normal for Geofabrik.

### B4. Referential integrity (2026-11-07)

`osmium check-refs -r` on Freiburg `261106` (14,630,534 nodes, 2,157,432 ways, 50,533 relations):

| Missing | Count |
| -- | -- |
| Nodes in ways | 0 |
| Nodes in relations | 6,682 |
| Ways in relations | 177,916 |
| Relations in relations | 4,420 |

*Outcome:* as expected. Ways are complete, and the missing members belong to relations that reach outside the region (routes, boundaries and the like). This is the baseline.

### C1. Diff format (2026-11-07)

Freiburg and Karlsruhe 4946–4950.

- `generator="osmium/1.16.0"`, consistent with `osmium derive-changes`. Every element start tag is on a line of its own, indented four spaces, with child lines for `tag`, `nd` and `member`.
- Each delete is in its own `<delete>` block (54 blocks for Freiburg 4950's 76 deletes, so some blocks hold several), and a delete is the complete old object: old `version`, old `timestamp`, and for nodes the coordinates.
- `tiebreak.pl` parsed all ten diffs, exited 0 and dropped nothing. A delete and a modify of the same object at the same version can't happen with `derive-changes`, so the OSM France artefact the tie-break exists for doesn't occur.

*Outcome:* the parser accepts Geofabrik's diffs, so the current sidecar wouldn't stop on them. The tie-break is a no-op for Geofabrik.

### C2. Deletes (2026-11-07)

Freiburg's 598 deletes over 4946–4950 are 546 nodes, 51 ways and 1 relation. 596 of them have a timestamp before 2026-10-31, as any `derive-changes` delete would, since it shows the last version. A sample of 100 (every sixth) was looked up in the OSM API (`/api/0.6/<type>/<id>`, one request per second):

| API result | Count | Meaning |
| -- | -- | -- |
| `410 Gone` | 99 | Real deletion |
| `200`, newer version | 1 | Node 464787763: Freiburg 4947 deletes v5, Karlsruhe 4947 modifies it to v6 (edited on 11-03 and moved across the border). Superseded |

*Outcome:* as feared, a real deletion and an object leaving the extract look the same: both are the old version. But objects leaving without an edit are rare: none in the sample. The one object that left was edited, and the other region's diff has the newer version, which `--simplify` already handles. D3 counts orphans over all deletes.

### C3. Roll-forward identity (2026-11-07)

| Start | Diffs | Compared with | `osmium diff` | OPL dump MD5 |
| -- | -- | -- | -- | -- |
| Freiburg `261101` | 4946, 4947, 4948 | `261104` | 16,836,075 same, 0 different, 0 left, 0 right | identical (`76a6a1e9…`) |
| Freiburg `261104` | 4949, 4950 (no dated file for 4949) | `261106` | 16,838,499 same, 0 different | identical (`3f68a0dd…`) |

*Outcome:* as expected, and exact. A Geofabrik extract plus its diffs reproduces each later extract byte for byte in OPL. So a single extract stays correct, and the sidecar can roll an older dated extract forward at bootstrap as it does now.

### C4. Creates and modifies that aren't edits (2026-11-07)

Over 4946–4950: Freiburg 6,217 creates, Karlsruhe 9,851, and **every create is version 1**. `derive-changes` never writes a modify with an unchanged version, since it compares objects by version. So in five days no object entered either extract without being edited.

*Outcome:* E5 doesn't need to test creates with old versions for these regions, though a polygon change would produce them. Over five days, objects entering or leaving the extracts without an edit are rare enough that D3's orphan count is the number that matters.

### B3. Cut strategy (2026-11-07)

`baden-wuerttemberg-261106` re-cut with each region's published `.poly`, compared with Geofabrik's `-261106` extract of the region (`osmium diff -s`; *left* = only in Geofabrik's, *right* = only in the re-cut):

| Region | `simple` | `complete_ways` | `smart` (default: multipolygons) | `smart -S types=any` |
| -- | -- | -- | -- | -- |
| Freiburg | left 164,491 | left 31,991 | **left 253** (247 nodes, 5 ways, 1 multipolygon) | left 253, right 428,366 |
| Karlsruhe | left 161,269 | left 26,182, right 16 | **left 4,403, right 21** | left 3,455, right 548,413 |

- `smart` is by far the closest, confirming that Geofabrik keeps multipolygons complete. `complete_ways` loses tens of thousands of objects.
- Every object missing from the re-cut is in the Baden-Württemberg file. For Karlsruhe they include 47 non-multipolygon relations (24 routes, 10 boundaries, superroutes, route masters, a waterway) and their multipolygon members, for example the Main river route `r7277`. Karlsruhe borders Bavaria, so the likeliest explanation is that Geofabrik cuts the districts from Germany or another larger file, in which these relations have members inside Karlsruhe's polygon that the Baden-Württemberg file doesn't contain. The 21 objects only in the re-cut (two ways and their nodes, at the Freiburg–Karlsruhe border and near 9.51 E 49.57 N) may come from a polygon edit or from osmium 1.15 versus 1.16 at the polygon edge. Neither explanation is confirmed.

*Outcome:* a re-cut of Baden-Württemberg isn't an exact reference for these districts. It differs by 0.002% (Freiburg) and 0.03% (Karlsruhe). An exact reference would need the Germany extract (about 4.5 GB), but D4 doesn't need one: the union of the regions' own extracts is the right reference for what multi-extract serves.

### D1. Overlap (2026-11-07)

On 4950 (`261106`): Freiburg has 14,630,534 nodes, 2,157,432 ways and 50,533 relations, and Karlsruhe 12,680,418, 2,218,637 and 43,385. `osmium merge` of the two has 27,189,793, 4,367,964 and 92,635, with `multiple_versions: false`. So 121,159 nodes, 8,105 ways and 1,283 relations are in both extracts, all at the same version.

*Outcome:* as expected. `osmium merge` de-duplicates the regions correctly, and the bootstrap snapshot needs no change.

### D2. Merged snapshot vs reference (2026-11-07, not run as written)

The reference in the plan (Baden-Württemberg cut with each polygon) isn't exact (B3), so D2 was replaced by D4's reference: `osmium merge` of the regions' own extracts for the same day.

### D3. Deletes that a merge gets wrong (2026-11-07, 5 days)

All deletes in Freiburg and Karlsruhe 4946–4950. A delete is an orphan if the other region's diff doesn't mention the object and the other region's extract for the previous day has it (so it still has it after the day). The previous-day extracts for 4946, 4947 and 4949 were made by rolling forward, which C3 showed is exact.

| Class | Freiburg deletes | Karlsruhe deletes |
| -- | -- | -- |
| Tied | 0 | 0 |
| Superseded | 2 | 0 |
| Orphan | **0** | **0** |
| Genuine (neither region has it after the day) | 596 | 1,637 |

The two superseded cases are nodes 464787763 and 464787764 in Freiburg 4947, both edited on 11-03 and moved into Karlsruhe (see C2). "Genuine" includes objects that left both regions, for example into Switzerland or France. That's also correct for the merge, since they leave the merged area too.

*Outcome:* no orphans in these five days, but the 96-day run below found 80 in five events.

### D4. Current merge on Geofabrik data (2026-11-07, 5 days)

`merged-4945` = `osmium merge` of the two regions' `261101` extracts. Each day's region diffs went through `tiebreak.pl` and `osmium merge-changes --simplify` in both input orders, and the five merged diffs were applied to `merged-4945`. The result was compared with `osmium merge` of the two `261106` extracts.

| Input order | `osmium diff` against merge of `261106` | OPL dump MD5 |
| -- | -- | -- |
| Freiburg, Karlsruhe | 31,650,392 same, 0 different, 0 left, 0 right | `0fda7204…` (same as the reference) |
| Karlsruhe, Freiburg | identical | `0fda7204…` |

The merged diffs for 4950 are byte-identical in both orders.

*Outcome:* over these five days the existing merge gives exactly the union of the two regions' extracts, because there were no orphans to get wrong. Over 96 days it doesn't (see below).

### D3, D4 over 96 days (2026-11-07)

The same checks over every diff from 4855 to 4950 (2026-08-02 to 2026-11-06), starting from the `260801` extracts (sequence 4854). Each day, both regions were rolled forward with their own diff, every delete that the other region's diff doesn't mention was looked up in the other region's previous-day extract, and the current merge (tie-break, then `merge-changes --simplify`) was chained from `merge(260801)`. Weekly, the chained result was compared with `osmium merge` of the two rolled-forward extracts. Script: `tools/long.sh` in the test cache, run in the image.

| Check | Result |
| -- | -- |
| Freiburg `260801` + 96 diffs vs Geofabrik's `261106` | identical (16,838,499 same) |
| Karlsruhe `260801` + 96 diffs vs Geofabrik's `261106` | identical (14,942,440 same) |
| Tie-break drops | 0 on every day |
| Chained merge vs `merge(261106)` | **80 objects missing** (`left=80`), nothing extra, nothing different |
| Missing objects vs orphan deletes found | **the same 80 objects, by id and version** |

Orphan events:

| Diff | Date | Orphans | Direction | What |
| -- | -- | -- | -- | -- |
| 4876 | 08-24 | 12 | Karlsruhe deletes, Freiburg keeps | `power=tower` nodes near Kehl (Ortenau, in Freiburg). A border-crossing power line was split; the Freiburg part became new way 1551970438, and the shortened old way no longer used the towers, so they left Karlsruhe's extract unchanged |
| 4892 | 09-09 | 36 | Freiburg deletes, Karlsruhe keeps | Untagged way nodes near 8.40 E 48.36 N |
| 4897 | 09-14 | 18 | Freiburg deletes, Karlsruhe keeps | Untagged way nodes |
| 4918 | 10-06 | 2 | Karlsruhe deletes, Freiburg keeps | Untagged way nodes |
| 4922 | 10-10 | 12 | Freiburg deletes, Karlsruhe keeps | Untagged way nodes |

All 80 are nodes: 12 tagged, 68 untagged. Each was removed from one region's extract unchanged because a way crossing the border stopped using it, while it stayed inside the other region's polygon.

*Outcome:* **this overturns the five-day result.** The current merge loses live objects for Geofabrik: 5 events and 80 nodes in 96 days for one pair of regions, and the losses persist until each node is next edited. The cause is the one the plan predicted. The checkpoints also show that orphans are the *only* problem: every other object matched every week. So a merge that also drops orphan deletes would have reproduced the union exactly over all 96 days.

The fix that follows from this, D5's stateful tie-break, is cheap with daily diffs. The sidecar keeps each region's extract and rolls it forward with that region's own diff, which C3 and this run show is exact. A region's delete is dropped when the object's id isn't in any other region's diff for the day and is in another region's extract. In this run that lookup (`osmium getid` on the other region's extract) took a few seconds per region per day under emulation, and the whole daily step for two regions, including rolling forward, took about 30–40 s. The cost is disk: one extract per region (here about 150 MB each) on top of what the sidecar already holds. D5's other option, diffing merged snapshots, would also work but needs a merge of all regions every day.
