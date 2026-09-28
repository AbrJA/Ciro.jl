# Ciro.jl examples

Each example has a different job — together they cover the library without
being three copies of the same kitchen-sink demo.

| Example | Theme | Focus |
|---|---|---|
| [`ai_chat`](ai_chat) | Real-time / product | SSE fan-out, async inference, chunked transcript streaming, uploads with `Expect: 100-continue`, per-route limits, overload shedding, `copy(ctx)` |
| [`ml_dashboard`](ml_dashboard) | Production / ops | Liveness & readiness probes, Prometheus metrics, access log + tail, token-protected admin, maintenance drain, per-route limits, graceful shutdown |
| [`feature_tour`](feature_tour) | API tour | Routing, typed params, wildcards, groups, middleware, status codes |
| [`ml_serving`](ml_serving) | Minimal service | JSON ML endpoints (needs `Pkg.add("JSON")`) |

---

## `ai_chat` — real-time AI chat rooms

Multiple browser tabs chat live over SSE; the assistant answers after simulated
inference on the async executor. This is the streaming/fan-out example.

### Run it

```bash
julia --project=. --threads=8 examples/ai_chat/server.jl
# optional positional args: server.jl [port] [backend]
# env: CIRO_PORT, CIRO_BACKEND, CIRO_WORKERS, CIRO_THINK_MS,
#      CIRO_ADMIN_TOKEN, CIRO_WORKERS_MAX
```

Open <http://localhost:8080> in two tabs, type in one, watch it arrive in both.
The assistant replies after ~0.4 s (`CIRO_THINK_MS`). Stop with Ctrl-C.

### What each piece demonstrates

| Capability | Where |
|---|---|
| SSE fan-out (broadcast to every subscriber) | `GET /api/v1/rooms/:id/events` |
| Async executor (simulated inference off the loop) | `POST /api/v1/rooms/:id/messages` |
| Typing indicator / presence events | SSE `typing` and `presence` events |
| Chunked streaming download | `GET /api/v1/rooms/:id/transcript` |
| Upload + per-route limit + `Expect: 100-continue` | `POST /api/v1/rooms/:id/import` (8 KB → 413) |
| Typed params, query params, 404s | `/api/v1/rooms/:id::Int/...` |
| Middleware (callable struct) | `RequireToken` on `/admin/stats` |
| `copy(ctx)` retention rule | message audit task |
| Telemetry | `GET /api/metrics`, `/admin/stats` |
| Overload shedding | `503` beyond `worker_threads`/`max_pending` |

### curl cheatsheet

```bash
curl -s localhost:8080/api/v1/rooms
curl -s localhost:8080/api/v1/rooms/1/messages
curl -s -X POST --data 'hello there' 'localhost:8080/api/v1/rooms/1/messages?as=me'
curl -s -N localhost:8080/api/v1/rooms/1/events          # SSE stream
curl -s localhost:8080/api/v1/rooms/1/transcript         # chunked download
curl -s -X POST --data 'line' localhost:8080/api/v1/rooms/1/import
curl -s localhost:8080/admin/stats -H 'X-Admin-Token: demo-token'

# overload shedding: 200 concurrent asks; expect a mix of 200 and 503
seq 1 200 | xargs -P200 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST --data 'hi' 'localhost:8080/api/v1/rooms/3/messages?as=load' | sort | uniq -c
```

### Notes

- **Each open SSE stream holds one async worker** for its lifetime, so
  `CIRO_WORKERS_MAX` (default 32) is the concurrent-stream ceiling; browsers
  also cap themselves at ~6 connections per host. Beyond the pool,
  `max_pending` queues and then requests get `503` (the xargs test shows it).
- The assistant is a mock: `sleep` stands in for inference.
- A subscriber whose 64-event queue fills is disconnected rather than buffered.

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
  an `AsyncExecutor`; see [`ai_chat`](ai_chat).
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
