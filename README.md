# Ciro.jl ⚡

> **Blazing-fast HTTP/1.1 for Julia** — low-latency REST APIs and high-concurrency ML
> model serving, with one tight request pipeline and a small, auditable native layer.

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#-license)
[![Julia 1.10+](https://img.shields.io/badge/Julia-1.10%2B-9558B2.svg)](#-requirements)

---

## ✨ Why Ciro?

- 🚀 **io_uring backend** (Linux): thread-per-core, one ring per Julia thread,
  `SO_REUSEPORT`, async I/O with a zero-allocation steady state.
- 🔌 **Portable Sockets backend**: blocking sockets + per-connection tasks, no native
  dependency — runs anywhere Julia does (`backend=:sockets`).
- 🧠 **One pipeline**: the io_uring server and the transport-free `Application` share
  `Runtime.dispatch`, so fakes can't drift from production.
- 🪞 **Zero-copy request views**: method, target, headers, and body are views into the
  connection buffer — request construction measured at **~480 B** (was ~4 KB).
- ⏱️ **Async executor**: slow handlers (model inference, blocking I/O) run on a bounded
  worker pool with automatic copy-on-escape and `503` shedding — the event loop never
  blocks.
- 🌊 **Streaming & SSE**: chunked responses and `text/event-stream` with backpressure;
  a disconnected client releases its worker instead of leaking it.
- 📊 **Observability**: opt-in `ServerMetrics` counters and one-line `AccessLog`, plus
  an `AbstractTelemetry` seam for custom metrics/tracing.
- 🛡️ **Strict framing & limits**: header/body/idle timeouts, size and connection caps;
  obs-fold, duplicate `Content-Length`, and CL+TE are rejected; header injection is
  impossible through `Response`.
- 🌊 **Graceful shutdown**: `stop!` (or SIGINT) stops accepting, flushes in-flight
  writes, closes idle connections, and drains within `shutdown_timeout`.
- 🗺️ **Trie router** with typed params, groups, wildcards, and 405 + `Allow`.
- 🧩 **Modular internals**: `Interface → Router → Runtime → HTTP → Backend → Core`.

> 📖 `ARCHITECTURE.md` is the design guide · `docs/DESIGN_REVIEW.md` the audit and
> staged plan · `WORKLOG.md` the progress tracker.

---

## 🧰 Requirements

- 🟣 Julia **1.10+**
- 🐧 For the io_uring backend: Linux **5.19+**, liburing headers, a C compiler
- 🍎🪟 The Sockets backend needs **no native dependencies**

```bash
# Ubuntu/Debian
sudo apt install liburing-dev
```

---

## 📦 Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the native backend (needed for `backend=:uring`):

```bash
cd lib && make
```

---

## 🚀 Quick Start

```julia
using Ciro

router = Trie()
get!(router, "/health",  ctx -> json("""{"status":"healthy"}"""))
post!(router, "/predict", ctx -> json("""{"prediction":0.42}"""))

# io_uring (default) on Linux; use backend=:sockets anywhere else
server = Server(; router, port=8080)
start!(server)
```

Run the included ML demo (needs `Pkg.add("JSON")`):

```bash
julia --project=. -t4 server.jl
curl http://localhost:3001/health
curl -X POST http://localhost:3001/api/v1/predict \
  -H 'Content-Type: application/json' -d '{"features":[1.0,2.0,3.0]}'
```

---

## ⚙️ Configuration & Limits

Everything is validated at construction, so configuration errors are **startup errors**:

```julia
Server(;
    router,
    backend           = :uring,       # :uring (Linux) or :sockets (portable)
    host              = "0.0.0.0",
    port              = 8080,
    backlog           = 8192,
    max_body_size     = 1_048_576,    # bytes
    max_header_bytes  = 65_536,
    header_timeout_ms = 5_000,
    body_timeout_ms   = 30_000,
    idle_timeout_ms   = 60_000,
    max_connections   = 1024,
    shutdown_timeout  = 5.0,          # seconds
)
```

### 🎯 Per-Route Limits

Override the body size or body timeout for individual routes. Body limits are
enforced from the framing headers — before the body is read — so an oversized
upload is rejected with `413` immediately:

```julia
post!(router, "/upload", upload_handler; limits=RouteLimits(max_body_size=8_000_000))
get!(router,  "/report", report_handler; limits=RouteLimits(body_timeout_ms=120_000))
```

Routes without limits inherit the server configuration; `-1` means inherit.

---

## 📚 API Highlights

### 🛣️ Routing

```julia
router = Trie()

get!(router,     "/path", handler)
post!(router,    "/path", handler)
put!(router,     "/path", handler)
delete!(router,  "/path", handler)
patch!(router,   "/path", handler)
head!(router,    "/path", handler)
options!(router, "/path", handler)
```

### 🧩 Typed Params, Wildcards & Groups

```julia
get!(router, "/models/:name",         ctx -> text(param(ctx, :name)))
get!(router, "/models/:id::Int",      ctx -> text("id=$(param(ctx, Int, :id))"))
get!(router, "/scores/:n::Float64",   ctx -> text("n=$(param(ctx, Float64, :n))"))
get!(router, "/files/*",              ctx -> text("serving: $(path(ctx))"))

group!(router, "/api/v1") do g
    get!(g,  "/models",       list_models)
    post!(g, "/predict/:id",  run_prediction)
end
```

### 🧾 Request & Response Helpers

```julia
# Request
path(ctx); query(ctx); queryparams(ctx)
header(ctx, "Content-Type"); body(ctx); rawbody(ctx)

# Response
text("Hello"); html("<h1>Hi</h1>"); json("""{"ok":true}""")
redirect("/login"); fail(404, "Not Found")
```

### 🪞 Zero-Copy Views — the Retention Rule

Handlers receive **views into the connection buffer**: `ctx.request.path`,
`ctx.request.headers`, and the body are valid **only until the handler returns**,
because the buffer is reused for the next request. Copy anything you keep:

```julia
get!(router, "/audit", ctx -> begin
    saved = copy(ctx)          # owned request + params
    @async process(saved)      # safe to hand to another task
    text("ok")
end)
```

> `body(ctx)` / `rawbody(ctx)` already return owned copies.
> Lifetime rules: `ARCHITECTURE.md` §4.4.

### ⏱️ Async Handlers — Slow Work Off the Event Loop

Give the server an `AsyncExecutor` and slow handlers no longer occupy a ring
thread. Requests are copied across the worker boundary automatically, and overload
is shed with `503 Service Unavailable` + `Retry-After`:

```julia
server = Server(; router,
                executor = AsyncExecutor(worker_threads=4, max_pending=256))
start!(server; nworkers=2)
```

Run Julia with more threads than event-loop workers (e.g. `julia --threads=6` for
`nworkers=2` + `worker_threads=4`) so handlers get real parallelism. Defaults are
safe; tune `worker_threads`/`max_pending` to your workload.

### 🌊 Streaming & Server-Sent Events

Stream a body incrementally: the handler runs on an async worker and every write
is flushed with backpressure (`close(w)` ends early; the stream ends when the body
returns):

```julia
server = Server(; router, executor = AsyncExecutor())

get!(router, "/ticks", ctx -> stream() do w
    for i in 1:10
        println(w, "tick ", i)
        sleep(0.5)
    end
end)                                  # Transfer-Encoding: chunked

get!(router, "/events", ctx -> sse() do send
    send("connected"; event="open")
    while true
        send("tick"; event="heartbeat")
        sleep(1)
    end
end)                                  # Content-Type: text/event-stream
```

Streaming requires `AsyncExecutor` (a synchronous handler would block the event
loop for the whole body). If the client disconnects, the next write throws
`StreamClosedError` and the worker is released. Supplying a `Content-Length`
header switches chunking off and sends bytes raw.

### 📊 Metrics & Access Logs

Attach an observer with `Server(; telemetry=...)`:

```julia
metrics = ServerMetrics()
server = Server(; router, telemetry=metrics)
start!(server)

metrics_snapshot(metrics)
# (requests = 12, responses = 12, status_2xx = 11, status_4xx = 1, status_5xx = 0,
#  exceptions = 0, bytes_in = 640, bytes_out = 1740)

Server(; router, telemetry=AccessLog())     # one line per response to stderr
Server(; router, telemetry=AccessLog(io))   # ... or any IO
# 2026-09-26T07:13:25.123 "GET /hello?x=1" 200 123 0.532ms
```

`AccessLog` lines include the request target, status, response bytes, and
elapsed time (for streams: to the end of the body). Implement
`AbstractTelemetry` (`telemetry_request!`, `telemetry_response!`,
`telemetry_read!`, `telemetry_exception!`) to feed Prometheus/OpenTelemetry.
The default `NullTelemetry` compiles away.

### 🧱 Middleware Pattern (Callable Struct)

```julia
struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(ctx::Context)::Response
    header(ctx, "Authorization") == "Bearer $(m.token)" || return fail(401)
    return m.handler(ctx)
end

get!(router, "/admin", WithAuth(admin_handler, ENV["SECRET"]))
```

---

## 🏗️ Architecture

```text
Interface   contracts and value types (Request/Response/Context, traits)
    ↑
Router      trie matching, params, groups, HEAD/405
    ↑
Runtime     the one pipeline: dispatch → executor → catcher
    ↑
HTTP        transport-agnostic state machine: incremental parse, framing,
            limits, timeouts, pipelining, response queueing
    ↑
Backend     AbstractIO adapters: UringIO (io_uring) and SocketsIO
    ↑
Core        Server: config + runtime state, workers, accept, drain
```

The HTTP layer talks to a backend **only** through the `AbstractIO` seam, and both
adapters pass the same wire acceptance suite.

---

## 🧪 Testing

```bash
(cd lib && make)   # required for the io_uring backend
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite includes **Aqua + JET**, allocation budgets, and **wire-level acceptance
tests** that run real servers over sockets for both backends.

---

## 📈 Benchmarks

```bash
(cd benchmarks/khttp && cargo build --release)
./benchmarks/khttp/target/release/server &
julia --project=. benchmarks/ciro_bench.jl &
./benchmarks/run_bench.sh
```

Requires [oha](https://github.com/hatoo/oha) (`cargo install oha`).

---

## ⚠️ Status & Limitations

- 🐧 io_uring is **Linux-only**; use `backend=:sockets` elsewhere. The Sockets backend
  uses a single accept loop (ignores `nworkers`), blocking writes without a send
  timeout, and IP-literal hosts only.
- 🛑 **SIGTERM cannot be intercepted** by Julia code (the runtime swallows it). Stop with
  `stop!` from another task, or SIGINT: systemd `KillSignal=SIGINT`, Docker
  `docker stop --signal=SIGINT`.
- 🌐 HTTP/1.1 only; no TLS or HTTP/2 in the core (terminate TLS at a reverse proxy).
- 📐 Route params are **zero-allocation on the served path** (ranges into the request
  path, resolved by `param`; `copy(ctx)` to retain). The public `route` helper still
  returns owned strings; compiled routing is on the roadmap. Streaming/SSE requires
  `AsyncExecutor` and occupies a worker per open stream (HTTP/1.1 only; no HTTP/2).

---

## 🔌 Extensibility

| Module | Role | Extension direction |
|---|---|---|
| `Interface` | Types and contracts | Custom `AbstractLogger` / `AbstractCatcher` / `AbstractExecutor` |
| `Router` | Trie dispatch | Implement another `AbstractRouter` |
| `Runtime` | Transport-free pipeline | Custom executors; embed via `Application` |
| `HTTP` | Protocol state machine | Shared by every backend |
| `Backend` / `Core` | I/O adapters and server wiring | Implement `AbstractIO` (kqueue, IOCP, libhv, ...) |

---

## 📄 License

MIT — see [LICENSE](LICENSE).
