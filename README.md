# overpass-coolify

Docker Compose deployments of an [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) server for [Coolify](https://coolify.io), built on the [`b1tw153/overpass-api`](https://github.com/b1tw153/Overpass-API) image. They serve regional extracts from [OpenStreetMap France](https://download.openstreetmap.fr/) and keep them current with minutely updates. Coolify deploys each one from this public repo, as a Docker Compose resource that builds a thin image adding the deployment's scripts to the upstream one. Each also runs with plain `docker compose`.

| Deployment | Use it when | Docs |
| -- | -- | -- |
| [`single-extract/`](single-extract/) | You need one OSM France extract | [README](single-extract/README.md) |
| [`multi-extract/`](multi-extract/) | You need several adjacent extracts served as one database. A sidecar merges their minute diffs into one replication stream. | [README](multi-extract/README.md), [design](multi-extract/DESIGN.md) |

Both deployments import the database with a one-shot init service that runs only when the database is empty, use a low `update_database` flush size so the import fits on a small host, and cap the query dispatcher's memory.

## License

GPL-3.0. See [LICENSE](LICENSE).
