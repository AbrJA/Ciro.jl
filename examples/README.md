# Ciro.jl examples

## `ml_dashboard` — a real-world ML inference dashboard

An end-to-end example that exercises every major Ciro capability behind a small
HTML/JS dashboard: JSON APIs, typed route params, middleware, a custom
telemetry observer, the async executor (simulated inference), Server-Sent
Events, per-route body limits, the zero-copy retention rule, and static files
served through a wildcard route.

### Run it

```bash
cd /path/to/Ciro.jl
(cd lib && make)                       # once, for the io_uring backend

julia --project=. --threads=8 examples/ml_dashboard/server.jl
# or: julia --project=. --threads=8 examples/ml_dashboard/server.jl 8080 sockets
```

Open <http://localhost:8080>. Stop with **Ctrl-C** (graceful drain).

> `--threads` should be larger than the executor's worker count (4 here) so
> handlers don't share threads with the event loops. On non-Linux, pass
> `sockets` as the second argument.

### What each piece demonstrates

| Capability | Where |
|---|---|
| `html` / `json` / `fail` / `redirect` responses | `GET /`, `GET /api/health`, 404/401 paths |
| Typed route params (`:id::Int`) + 404 | `GET /api/v1/models/:id` |
| Route groups, wildcard routes | `/api/v1/*`, `GET /static/*` |
| Middleware (callable structs) | `WithServerHeader`, `RequireToken` on `/admin/stats` |
| Zero-copy request views + `copy(ctx)` | `POST /api/v1/predict`, `GET /api/v1/audit` |
| Async executor (slow handler off the loop) | `POST /api/v1/predict` (`sleep` = inference) |
| Streaming / SSE (`sse`, backpressure, disconnect) | `GET /api/v1/events` |
| Per-route limits (`RouteLimits`) | `POST /api/v1/upload` (4 KB → `413`) |
| Custom `AbstractTelemetry` (metrics + access log) | `DemoTelemetry`, `GET /api/metrics` |
| Per-route static files (traversal-guarded) | `GET /static/app.js` |

### curl cheatsheet

```bash
curl -s localhost:8080/api/health
curl -s localhost:8080/api/v1/models
curl -s localhost:8080/api/v1/models/2
curl -s -X POST --data '1.0,2.5,3.0' 'localhost:8080/api/v1/predict?model=2'
curl -s -X POST --data "$(head -c 100 /dev/zero | tr '\0' x)" localhost:8080/api/v1/upload
curl -s -o /dev/null -w '%{http_code}\n' -X POST --data "$(head -c 8000 /dev/zero | tr '\0' x)" \
     localhost:8080/api/v1/upload            # 413
curl -s -N localhost:8080/api/v1/events      # SSE stream
curl -s localhost:8080/admin/stats -H 'X-Admin-Token: demo-token'
```

### Notes

- Streaming responses require `AsyncExecutor` (a synchronous handler would
  block the event loop for the whole body); a sync server answers `500`.
- **Each open SSE stream holds one async worker for its lifetime.** The example
  uses `worker_threads = 32, max_pending = 128`: with more than 32 concurrent
  streams (one per dashboard tab, plus reloads that have not been reaped yet)
  requests queue up to `max_pending` and are then shed with `503`. If the Live
  events panel shows "stream lost — reconnecting…", the pool is exhausted —
  close extra tabs or raise `worker_threads`.
- The example's access log goes to stdout; metrics are available as JSON.
- `GET /static/*` is a minimal example of serving files by hand (no dotfile or
  symlink policy beyond `..` rejection) — it is not a production static server.
