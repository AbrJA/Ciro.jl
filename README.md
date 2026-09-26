# Ciro.jl

High-performance HTTP/1.1 framework for Julia, built for low-latency REST APIs and
high-concurrency ML serving.

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions)

## Why Ciro?

Ciro serves models and APIs directly from Julia with one tight request pipeline and a
small, auditable native layer.

- **io_uring backend** (Linux): thread-per-core, one ring per thread, `SO_REUSEPORT`,
  async I/O with a zero-allocation steady state. See `backend=:uring` (default).
- **Portable Sockets backend**: blocking sockets plus per-connection tasks, no native
  dependency; runs anywhere Julia does. See `backend=:sockets`.
- **One pipeline**: the io_uring server and the transport-free `Application` share
  `Runtime.dispatch`, so fakes cannot drift from production.
- **Zero-copy request views**: method, target, headers, and body are views into the
  connection buffer; request construction measured ~480 B (was ~4 KB).
- **Strict framing and limits**: header/body/idle timeouts, `max_header_bytes`,
  `max_body_size`, `max_connections`; obs-fold, duplicate `Content-Length`, and CL+TE
  are rejected; header injection is impossible through `Response`.
- **Graceful shutdown**: `stop!` (or SIGINT) stops accepting, flushes in-flight writes,
  closes idle connections, and drains within `shutdown_timeout`.
- **Trie router** with typed params, groups, wildcards, and 405 + `Allow`.

`ARCHITECTURE.md` is the design guide; `docs/DESIGN_REVIEW.md` is the audit and staged
plan; `WORKLOG.md` tracks progress.

## Requirements

- Julia 1.10+
- io_uring backend: Linux kernel 5.19+, liburing headers, a C compiler
- Sockets backend: no native dependencies

Ubuntu/Debian:

```bash
sudo apt install liburing-dev
```

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the native backend (needed for `backend=:uring`):

```bash
cd lib && make
```

## Quick start

```julia
using Ciro

router = Trie()
get!(router, "/health", ctx -> json("""{"status":"healthy"}"""))
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

## Configuration and limits

Everything is validated at construction, so configuration errors are startup errors:

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

## API highlights

### Routing

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

### Typed params, wildcards, groups

```julia
get!(router, "/models/:name", ctx -> text(param(ctx, :name)))
get!(router, "/models/:id::Int", ctx -> text("id=$(param(ctx, Int, :id))"))
get!(router, "/scores/:n::Float64", ctx -> text("n=$(param(ctx, Float64, :n))"))
get!(router, "/files/*", ctx -> text("serving: $(path(ctx))"))

group!(router, "/api/v1") do g
    get!(g,  "/models", list_models)
    post!(g, "/predict/:id", run_prediction)
end
```

### Request and response helpers

```julia
# Request
path(ctx); query(ctx); queryparams(ctx)
header(ctx, "Content-Type"); body(ctx); rawbody(ctx)

# Response
text("Hello"); html("<h1>Hi</h1>"); json("""{"ok":true}""")
redirect("/login"); fail(404, "Not Found")
```

### Zero-copy views: the retention rule

Handlers receive views into the connection buffer. `ctx.request.path`,
`ctx.request.headers`, and the body are valid **only until the handler returns**,
because the buffer is reused for the next request. Copy anything you need to keep:

```julia
get!(router, "/audit", ctx -> begin
    saved = copy(ctx)          # owned request + params
    @async process(saved)      # safe to hand to another task
    text("ok")
end)
```

`body(ctx)` and `rawbody(ctx)` already return owned copies. See `ARCHITECTURE.md` §4.4.

### Middleware pattern (callable struct)

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

## Architecture

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

The HTTP layer talks to a backend only through the `AbstractIO` seam, and both
adapters pass the same wire acceptance suite. Details: `ARCHITECTURE.md`.

## Testing

```bash
# required for the io_uring backend
(cd lib && make)
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite includes Aqua + JET, allocation budgets, and wire-level acceptance tests
that run real servers over sockets for both backends.

## Benchmarks

```bash
(cd benchmarks/khttp && cargo build --release)
./benchmarks/khttp/target/release/server &
julia --project=. benchmarks/ciro_bench.jl &
./benchmarks/run_bench.sh
```

Requires oha (`cargo install oha`).

## Status and limitations

- io_uring is Linux-only; use `backend=:sockets` elsewhere. The Sockets backend uses a
  single accept loop (ignores `nworkers`), blocking writes without a send timeout, and
  IP-literal hosts only.
- **SIGTERM cannot be intercepted by Julia code** (the runtime swallows it). Stop with
  `stop!` from another task, or SIGINT: systemd `KillSignal=SIGINT`, Docker
  `docker stop --signal=SIGINT`.
- HTTP/1.1 only; no TLS or HTTP/2 in the core (terminate TLS at a reverse proxy).
- Routing still allocates a small params vector on parameterized routes; compiled
  routing and the async executor are on the roadmap.

## Extensibility

| Module | Role | Extension direction |
|---|---|---|
| `Interface` | Types and contracts | Custom `AbstractLogger`/`AbstractCatcher`/`AbstractExecutor` |
| `Router` | Trie dispatch | Implement another `AbstractRouter` |
| `Runtime` | Transport-free pipeline | Custom executors; embed via `Application` |
| `HTTP` | Protocol state machine | Shared by every backend |
| `Backend`/`Core` | I/O adapters and server wiring | Implement `AbstractIO` (kqueue, IOCP, libhv, ...) |

## License

MIT
