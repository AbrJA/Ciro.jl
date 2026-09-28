# Ciro.jl examples

Each example has a different job — together they cover the library without
being three copies of the same kitchen-sink demo.

| Example | Theme | Focus |
|---|---|---|
| [`ml_dashboard`](ml_dashboard) | Production / ops | Liveness & readiness probes, Prometheus metrics, access log + tail, token-protected admin, maintenance drain, per-route limits, graceful shutdown |
| [`feature_tour`](feature_tour) | API tour | Routing, typed params, wildcards, groups, middleware, status codes |
| [`ml_serving`](ml_serving) | Minimal service | JSON ML endpoints (needs `Pkg.add("JSON")`) |

---

## `ml_dashboard` — a production-style ops console

A small model service with the things you actually deploy, plus an HTML
console that polls it.

### Run it

```bash
cd /path/to/Ciro.jl
(cd lib && make)                       # once, for the io_uring backend

julia --project=. examples/ml_dashboard/server.jl
# or, on non-Linux: CIRO_BACKEND=sockets julia --project=. examples/ml_dashboard/server.jl
```

Open <http://localhost:8080>. Stop with **Ctrl-C** (graceful drain).

### Configuration (environment)

| Variable | Default | Meaning |
|---|---|---|
| `CIRO_PORT` | `8080` | Listen port |
| `CIRO_BACKEND` | `uring` | `uring` (Linux) or `sockets` |
| `CIRO_WORKERS` | `nthreads()` | Event-loop workers |
| `CIRO_LOG` | *(stdout)* | Append the access log to this file |
| `CIRO_ADMIN_TOKEN` | `demo-token` | Token for `/admin/*` (`X-Admin-Token`) |
| `CIRO_MAX_BODY` | `1048576` | Server-wide body limit |
| `CIRO_MAX_CONNECTIONS` | `1024` | Over-limit connections get `503` + `Retry-After` |

### What each piece demonstrates

| Capability | Where |
|---|---|
| Liveness / readiness probes | `GET /healthz`, `GET /readyz` (`503` in maintenance) |
| Prometheus metrics | `GET /metrics` (text exposition) |
| Metrics for a UI | `GET /api/metrics` (JSON) |
| Access log (stdout or file) + in-memory tail | `OpsTelemetry`, `GET /admin/log/tail` |
| Custom `AbstractLogger` | `ConsoleLogger` (startup/stop/warnings) |
| Middleware (callable structs) | `WithServiceHeader` on `/healthz`, `RequireToken` on `/admin/*` |
| Maintenance drain | `POST /admin/maintenance` with body `on` / `off` |
| Effective config + live connection count | `GET /admin/config`, `GET /admin/stats` |
| Per-route body limits | `POST /api/v1/upload` (4 KB → `413`) |
| Typed route params + 404 | `GET /api/v1/models/:id::Int` |
| Static files (traversal-guarded wildcard) | `GET /static/*` |
| Graceful shutdown | Ctrl-C / `SIGINT` drains in-flight responses |

### curl cheatsheet

```bash
curl -s localhost:8080/healthz
curl -s localhost:8080/readyz
curl -s localhost:8080/metrics | head
curl -s localhost:8080/api/v1/models/2
curl -s -o /dev/null -w '%{http_code}\n' -X POST --data "$(head -c 8000 /dev/zero | tr '\0' x)" \
     localhost:8080/api/v1/upload                     # 413 (4 KB route limit)
curl -s localhost:8080/admin/stats -H 'X-Admin-Token: demo-token'
curl -s -X POST --data on  localhost:8080/admin/maintenance -H 'X-Admin-Token: demo-token'
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/readyz   # 503 while draining
curl -s -X POST --data off localhost:8080/admin/maintenance -H 'X-Admin-Token: demo-token'
```

### Production notes

- The console uses `SyncExecutor` (handlers are cheap). Slow handlers belong on
  an `AsyncExecutor`; see the `ai_chat` example (next).
- `CIRO_LOG=/var/log/ciro-access.log` makes the access log appendable and
  tail-able; the admin tail keeps the last 50 lines in memory.
- Scrape `GET /metrics` from Prometheus; the counters are atomic and safe to
  read from any task.
- Over-limit connections and oversized uploads are answered (`503`/`413`)
  rather than silently dropped.

## `feature_tour` — routing/API tour

```bash
julia --project=. --threads=auto examples/feature_tour/server.jl   # :3001
```

Every routing and request feature in one server: typed params, multi-params,
wildcards, groups, custom middleware, 401/500 handling, HEAD.

## `ml_serving` — minimal JSON ML service

```bash
julia --project=. -t4 examples/ml_serving/server.jl                # :3001 (needs Pkg.add("JSON"))
```

`/health`, `/api/v1/model`, `/api/v1/predict`, `/api/v1/batch`, `/api/v1/echo`
with a custom JSON error catcher.
