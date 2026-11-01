# Single-extract Overpass deployment

This folder holds a Docker Compose deployment of the [`b1tw153/overpass-api`](https://hub.docker.com/r/b1tw153/overpass-api) image, serving an Overpass API for the Ontario Golden Horseshoe extract from openstreetmap.fr. The upstream image's own documentation is in the [b1tw153/Overpass-API](https://github.com/b1tw153/Overpass-API) repository.

The extract and its minutely diffs both come from OpenStreetMap France, because the region's diffs match only OSM France's own extract. To serve several adjacent extracts as one database, see [`../multi-extract/`](../multi-extract/).

This setup replaced one based on the `wiktorn/overpass-api` image. The b1tw153 image differs from it in ways that shape this Compose file: it doesn't initialize the database on its own (hence the separate `overpass-init` service), it uses different environment variables and volume paths (`/opt/overpass/db`, `/opt/overpass/diff`), and it serves on port 8080.

## Files

- `b1tw153.yml` is the Compose file. It defines two services that share the `overpass-db` volume: `overpass-init` (one-shot database import) and `overpass` (the API server and update loop). The `overpass` service also mounts an `overpass-diff` volume, so downloaded minutely diffs and `fetch_osc.log` survive redeploys. Both services use one image, set once at the top of the file (`x-overpass-image`). It defaults to a pinned tag and can be overridden with the `OVERPASS_IMAGE` environment variable, for example in Coolify, without editing the file.
- `init.sh` is a plain shell version of the `overpass-init` command from the Compose file. It does the same thing, but can be read, run and tested outside Compose.

## Deploying on Coolify

Create a Docker Compose resource from the pasted contents of `b1tw153.yml`, and give the `overpass` service its domain with 8080 as the container port. Clients use the bare domain, without a port. Coolify names the volumes `<resource-uuid>_<volume>`, so the database volume is `<resource-uuid>_overpass-db`.

## Compose settings

These settings in `b1tw153.yml` matter for a small host:

- **Pinned image.** The default is `b1tw153/overpass-api:0.7.62.11-r21`, the first release whose `fetch_osc.sh` polls download.openstreetmap.fr correctly. Override it with `OVERPASS_IMAGE`.
- **`stop_grace_period: 120s`** on `overpass`. On SIGTERM the entrypoint waits for the diff update in progress before stopping. Compose's 10-second default would kill it mid-write and risk corrupting the database. Minutely diffs on this extract apply in seconds, so 120 s is plenty.
- **`DISPATCHER_BASE_SPACE: 2147483648`** (2 GiB). This is the total memory running queries may reserve, at 512 MiB per query by default. The entrypoint's default of 768 GiB lets heavy queries OOM a small host instead of being refused. The areas dispatcher gets the same value as a separate budget.
- **No `OVERPASS_UPDATE_FREQUENCY`.** The image always detects the update frequency from the diff feed and overwrites this variable, so setting it has no effect.
- **The `overpass-diff` volume** at `/opt/overpass/diff` keeps downloaded diffs and `fetch_osc.log` across redeploys.

## Healthcheck

The `overpass` healthcheck probes `http://localhost:8080/api/status`, the same endpoint the image's own check uses, with a short start period, since the database is already imported when the server starts. Two things to know if you change it:

- **Avoid square brackets in the URL**, or pass `curl -g`. A query such as `[out:json]` is otherwise read as a curl URL glob and fails with "bad range", so the check never passes.
- **Coolify only routes to healthy containers.** Its Traefik proxy drops a container that isn't Docker-healthy (still `starting`, or `unhealthy`) and answers HTTP 503 "no available server" with Traefik's default certificate. That looks like a DNS or network fault, but it is the healthcheck. Check the container's health with `docker inspect -f '{{json .State.Health}}' <container>`, whose `Log` shows the check's output.

## What init.sh does

`init.sh` builds the initial Overpass database the first time the stack starts. It runs these steps:

1. **Skips if already initialized.** If `$OVERPASS_DB_DIR/replicate_id` exists, the database is valid, so the script prints a message and exits 0. This makes it safe to run on every `docker compose up`.
2. **Clears stale files.** If there is no `replicate_id`, any files in the database directory are left over from a failed import and are deleted.
3. **Picks the metadata mode.** `OVERPASS_META_MODE` maps to an `update_database` flag: `yes` is `--meta`, `attic` is `--keep-attic`, anything else is `--data-only`.
4. **Downloads the extract.** It fetches the `.osm.pbf` from `IMPORT_OSM_DATA_SOURCE` with `curl`, retrying on failure and aborting stalled transfers.
5. **Checks the MD5 if one is published.** It fetches `<source>.md5` and compares its hash with the download. A match is logged as verified. A missing `.md5` (HTTP 404), a failed fetch or a mismatch only logs a message or warning, and the import continues.
6. **Imports it.** `osmium cat` converts the PBF to OSM XML and pipes it into `update_database`, which writes the Overpass database. `IMPORT_FLUSH_SIZE` (millions of elements buffered before a flush) trades import speed for peak memory. The default of 16 gets OOM-killed on a small host, so this deployment uses 4. Drop it to 2 or 1 if 4 still fails. The downloaded PBF is deleted once the import finishes.
7. **Records the replication position.** `bisect_timestamp.sh` finds the sequence number in the diff feed (`OVERPASS_DIFF_URL`) that matches the timestamp of the imported data. The script writes it to `replicate_id` only if `bisect_timestamp.sh` succeeds and returns a value. The running server uses this to know where to start applying minutely updates.

`replicate_id` is written last, and only on success, so it doubles as the "import completed" marker. If the script dies at any earlier step, the next run starts again from a clean directory.

## Why it is a custom command in the Compose setup

The upstream image can import this source with its own `import_osm_data.sh`, but that script gives no control over import memory and isn't safe to rerun on every deploy. An inline command in a separate init service solves several problems:

- **Memory control.** The upstream script runs `update_database` without `--flush-size`, so it uses the default of 16, which exhausts memory on a small host. Running `update_database` directly lets us pass `--flush-size`.
- **Checksums that can't block the import.** The upstream script fetches `<source>.md5`. It skips verification on a 404, but exits on a mismatch. openstreetmap.fr publishes no `.md5` for `<region>-latest.osm.pbf` (the URL this deployment uses), only for `<region>.osm.pbf`, which is the same file. That `.md5` can be stale: on 30 Oct 2026 the Golden Horseshoe `.md5` was dated 29 Oct 01:01, the PBF 30 Oct 15:01, and the hashes didn't match. A strict check against the plain URL would therefore fail the import. `init.sh` checks the hash when a `.md5` exists, but only warns on a mismatch.
- **Separation of the one-time import from the server.** The import takes a long time and a lot of memory, and should happen exactly once. `overpass-init` has `restart: "no"`, and the `overpass` service uses `depends_on` with `condition: service_completed_successfully`, so the server only starts once the import has finished successfully. If the import fails, the server doesn't start against a half-built database, and the failure shows up as a failed init container instead of an unhealthy server.
- **Idempotence.** The upstream script neither skips a database that already exists nor clears files left by a failed import. The `replicate_id` check means re-running `docker compose up` (redeploys, restarts, new Coolify deploys) doesn't re-download and re-import the data, and a failed import is cleaned up before the next attempt.
- **Disk.** The upstream script leaves the downloaded PBF in the database directory. `init.sh` deletes it after the import.
- **A correct starting point for updates.** The server is configured with `OVERPASS_REPLICATE_ID: auto`, which relies on the `replicate_id` file. Computing it from the extract's timestamp avoids a gap or overlap between the imported snapshot and the minutely diffs.

### A note on `$$` in the Compose file

Inside `b1tw153.yml` the same script is inlined as the `command`, with every shell `$` written as `$$`. Compose interpolates a single `$` when it parses the file, using variables from the host or `.env` rather than the service's own environment, so an unescaped `$DB` would arrive in the container empty. `init.sh` has no such escaping because the shell reads it directly.

## Running init.sh by hand

Run it through Compose as a one-off `overpass-init` container, from this folder:

```sh
docker compose -f b1tw153.yml run --rm --no-deps \
  -v "$PWD/init.sh:/init.sh:ro" \
  --entrypoint /bin/bash \
  overpass-init /init.sh
```

This uses the service's image (including any `OVERPASS_IMAGE` override), environment and database volume, so nothing is repeated here. A plain `docker run -v overpass-db:...` would not work: Compose prefixes volume names with the project name (`single-extract_overpass-db` when run from this folder), so it would import into a new, empty volume. To target a stack deployed under another project name, such as Coolify's (the resource UUID), add `-p <project>`. `docker volume ls` shows the prefix in front of `_overpass-db`.

All settings (`OVERPASS_DB_DIR`, `OVERPASS_DIFF_DIR`, `OVERPASS_META_MODE`, `IMPORT_OSM_DATA_SOURCE`, `OVERPASS_DIFF_URL`, `IMPORT_OSM_COMPRESSION_METHOD`, `IMPORT_FLUSH_SIZE`, `OVERPASS_BIN_DIR`) have defaults matching the Compose file and can be overridden with `-e`.
