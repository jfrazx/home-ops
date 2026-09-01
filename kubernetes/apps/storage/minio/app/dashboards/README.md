# MinIO Grafana dashboards

Vendored from `minio/minio` at tag `RELEASE.2025-04-22T22-12-26Z`, matching the
image tag pinned in `../helmrelease.yaml`:

| File                 | Upstream path                                              |
| -------------------- | ---------------------------------------------------------- |
| `minio-cluster.json` | `docs/metrics/prometheus/grafana/minio-dashboard.json`      |
| `minio-node.json`    | `docs/metrics/prometheus/grafana/node/minio-node.json`      |
| `minio-bucket.json`  | `docs/metrics/prometheus/grafana/bucket/minio-bucket.json`  |

These are checked in rather than fetched by URL. The upstream repository is
**archived**, so it can be made private or removed at any time — and Grafana's
`dashboards: url:` mechanism re-downloads on every pod start, which would turn
an upstream disappearance into a Grafana startup failure.

Two edits were applied to each file on import:

1. `__inputs` was dropped and the `${DS_PROMETHEUS}` placeholder resolved to the
   `prometheus` datasource uid. The sidecar provisions files verbatim and does
   not perform the grafana.com import-time substitution.
2. The `scrape_jobs` variable is filtered to `/^minio(-.*)?$/` and defaults to
   all values. MinIO's v2 cluster, node and bucket metrics are three separate
   scrape jobs, and a single dashboard mixes families from more than one of
   them, so pinning one job would leave panels empty.
