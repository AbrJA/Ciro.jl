# Ciro.jl example: the playground

One app that exercises the library end to end, with a small UI so you can see it
work. Two servers start from the same routes:

- **async executor** — `http://localhost:8080` (streaming; slow work stays off the event loop)
- **sync executor** — `http://localhost:8081` (streaming answers `500`; slow work blocks, see below)

The page has an executor switch, so you can point every button at either server.

## Run it

```bash
cd /path/to/Ciro.jl
(cd lib && make)                       # once, for the io_uring backend

julia --project=. --threads=8 examples/playground/server.jl
# optional positional args: server.jl [port] [backend]
# non-Linux:  julia --project=. examples/playground/server.jl 8080 sockets
```

Open <http://localhost:8080>. Stop with **Ctrl-C** (graceful drain).

### Configuration (environment)

| Variable | Default | Meaning |
|---|---|---|
| `CIRO_PORT` | `8080` | Async server port (sync = port + 1) |
| `CIRO_BACKEND` | `uring` | `uring` (Linux) or `sockets` |
| `CIRO_WORKERS` | `nthreads()` | Event-loop workers (async server is capped at `nthreads-1`) |
| `CIRO_TOKEN_MS` | `40` | Delay between streamed tokens |
| `CIRO_THINK_MS` | `400` | Simulated inference time |
| `CIRO_ADMIN_TOKEN` | `demo-token` | Token for `/admin/*` |
| `CIRO_WORKER_THREADS` | `32` | Async handler pool |

## What each piece demonstrates

| Capability | Where in the UI |
|---|---|
| SSE token streaming (`sse`, `sse_comment`) | **Generate → Stream (SSE)** types live |
| Chunked response streaming (`stream`) | **Generate → Stream (.txt)** |
| Async executor (slow handler off-loop) | **Predict**, and **Slow + ping health** on the async server |
| Sync executor (blocking) | **Slow + ping health** on the sync server with `CIRO_WORKERS=1` |
| Streaming requires AsyncExecutor | **Stream (SSE)** on the sync server → `500` JSON |
| JSON request/response, body, `content_type` | **Predict** |
| Query params | `?prompt=&style=`, `/api/v1/echo?q=hi` |
| Headers | `/api/v1/echo` shows `Host` / `User-Agent` |
| Typed params (`:id::Int`) + `404` | **Routes → GET /api/v1/models/2, /99** |
| Wildcards | `/api/v1/files/a/b/c`, `/static/*` |
| `405` + `Allow` | **Routes → DELETE /api/v1/predict** |
| Redirect | **Routes → GET /old** (`302`) |
| Auto-HEAD (no body, GET length) | **Routes → HEAD /api/v1/models/1** |
| Per-route body limit | **Upload 8 KB → 413** (route limit is 4 KB) |
| `Expect: 100-continue` | curl recipe below |
| Overload shedding (`503`) | 48 concurrent predicts against an 8-worker/24-pending pool |
| Middleware (callable struct) | `RequireToken` on `/admin/*`, `WithServiceHeader` on `/healthz`, `WithCORS` on every route |
| CORS across the two origins | `Access-Control-Allow-Origin: *` + `OPTIONS` preflight (DELETE/admin paths) |
| Custom catcher | `/api/v1/boom` → JSON `500` with the exception type |
| Custom logger | `ConsoleLogger` (startup/stop on stderr) |
| Custom telemetry | `PlaygroundTelemetry` (metrics + access log + tail) |
| Metrics: Prometheus + JSON | `/metrics`, `/api/metrics`, panels in the UI |
| Access log tail | `/admin/log/tail` panel |
| Zero-copy retention rule (`copy(ctx)`) | `/api/v1/audit` hands an owned copy to a task |
| Probes + maintenance drain | `/healthz`, `/readyz` (`503` while draining) |
| Static files (traversal-guarded) | the page assets via `/static/*` |
| Graceful shutdown, backend choice | Ctrl-C; `[port] [backend]` args |

Not in the UI (covered by tests): raw framing/pipelining, CRLF/CL/TE defenses,
header/body/idle timeouts, `max_connections`, custom `AbstractRouter`/
`AbstractBackend`, `Application`/`FakeTransport`.

## curl cheatsheet

```bash
curl -s localhost:8080/healthz
curl -sN 'localhost:8080/api/v1/generate?prompt=hello&style=haiku'   # SSE tokens
curl -s  'localhost:8080/api/v1/generate.txt?prompt=hello'           # chunked text
curl -s -X POST --data '1,2,3' 'localhost:8080/api/v1/predict?model=2'
curl -s  'localhost:8080/api/v1/echo?q=hi'
curl -s  localhost:8080/api/v1/files/a/b/c
curl -s  localhost:8080/metrics | head

# Expect: 100-continue (curl sends it automatically for larger bodies)
curl -v -X POST --data-binary @<(head -c 2000 /dev/zero | tr '\0' x) localhost:8080/api/v1/upload

# overload shedding: expect a mix of 200 and 503
seq 1 200 | xargs -P200 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST --data '1,2,3' localhost:8080/api/v1/predict | sort | uniq -c

# admin (401 without the token)
curl -s localhost:8080/admin/stats -H 'X-Admin-Token: demo-token'
```

## Notes

- **Async vs sync:** the async server runs slow handlers on workers, so other
  requests stay responsive. On the sync server with `:uring` and one worker
  (`CIRO_WORKERS=1`), a slow handler blocks the engine — press **Slow + ping
  health** on both to see it.
- **Each open stream holds one async worker** for its lifetime; the pool
  (`CIRO_WORKER_THREADS`, default 32) is the concurrent-stream ceiling.
- **SSE framing:** `sse()`'s sender emits one event per call — pass data, not
  preformatted `event:`/`data:` lines. Keepalives use `sse_comment`.
- **CORS:** the async (`:8080`) and sync (`:8081`) servers are different
  origins, so the example wraps routes in a `WithCORS` middleware and answers
  `OPTIONS` preflight for the paths the UI calls with `DELETE` or
  `X-Admin-Token`. (A built-in CORS helper is a candidate for the library
  backlog; the example shows the pattern for now.)
- The example is tested by `test/playground_test.jl` (48 assertions, real
  clients, `:uring` when the native library is present) as part of `Pkg.test()`.
