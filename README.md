# Ciro.jl

A blazing-fast, lightweight HTTP framework for Julia — designed for high-concurrency ML model serving.

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions)

## Why Ciro?

Julia is the language of scientific computing and ML. Ciro lets you serve models **directly from Julia** without Python bridges, gRPC complexity, or serialization overhead.

- **io_uring backend** — Linux kernel async I/O with zero-copy writes
- **Thread-per-core** — one io_uring ring per Julia thread, no cross-thread locking
- **Zero-cost middleware** — functor chain fully monomorphized by the compiler
- **Type-stable routing** — O(path depth) trie dispatch, typed params, route groups
- **Pool-based allocation** — ConnectionPool + BufferPool eliminate malloc in steady state
- **Modular architecture** — each module is independently replaceable/extensible

## Requirements

- **Linux** with kernel ≥ 5.19 (io_uring multishot accept)
- **liburing** development headers (`apt install liburing-dev`)
- **Julia** ≥ 1.10
- **GCC** for the C library

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the C backend:

```bash
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring
```

## Quick Start — ML Model Server

```julia
using Ciro

# Your model (loaded once, served many times)
const MODEL = load_my_model("weights.bson")

function predict(ctx::Context)
    input = body(ctx)
    isempty(input) && return fail(400, "Empty input")
    result = MODEL(parse_input(input))
    return json("""{"prediction":$result}""")
end

function health(ctx::Context)
    json("""{"status":"healthy","model":"loaded"}""")
end

# Build router
router = Trie()
get!(router, "/health", health)
post!(router, "/predict", predict)

# Start with all threads
server = Server(; router, port=8080)
start!(server)
```

```bash
julia --threads=auto --project=. serve.jl
```

## API Reference

### Routing

```julia
router = Trie()

# HTTP methods
get!(router,     "/path", handler)
post!(router,    "/path", handler)
put!(router,     "/path", handler)
delete!(router,  "/path", handler)
patch!(router,   "/path", handler)
head!(router,    "/path", handler)   # auto-generated from GET if not set
options!(router, "/path", handler)
```

#### Route Parameters

```julia
# Untyped — any segment matches
get!(router, "/models/:name", ctx -> text(param(ctx, :name)))

# Typed — router rejects non-matching at dispatch (handler never called)
get!(router, "/models/:id::Int",    ctx -> text("id=$(param(ctx, Int, :id))"))
get!(router, "/scores/:n::Float64", ctx -> text("n=$(param(ctx, Float64, :n))"))
get!(router, "/runs/:uuid::UUID",   ctx -> text(param(ctx, :uuid)))

# Wildcard — catches all deeper paths
get!(router, "/files/*", ctx -> text("serving: $(path(ctx))"))
```

#### Route Groups

```julia
group!(router, "/api/v1") do g
    get!(g,    "/models",      list_models)
    post!(g,   "/models",      create_model)
    get!(g,    "/models/:id",  get_model)
    post!(g,   "/predict/:id", run_prediction)

    group!(g, "/admin") do a
        get!(a, "/stats", admin_stats)
    end
end
```

### Handlers

Every handler receives a `Context` and returns a `Response`:

```julia
function my_handler(ctx::Context)
    id   = param(ctx, Int, :id)         # typed route parameter
    ua   = header(ctx, "User-Agent")    # request header
    data = body(ctx)                     # body as String
    qp   = queryparams(ctx)             # Dict{String,String}

    return json("""{"result":"ok"}""")
end
```

### Response Builders

```julia
text("Hello"; status=200)                    # text/plain
html("<h1>Hi</h1>")                          # text/html
json("""{"key":"value"}""")                  # application/json
json(raw_bytes::Vector{UInt8}; status=200)   # application/json from bytes
redirect("/login")                           # 302 Found
redirect("/new"; status=301)                 # 301 Moved Permanently
fail(404, "Not Found")                       # error response
fail(400)                                    # error with empty body
```

### Request Utilities

```julia
# Path and query
path(ctx)                            # "/models/42" (no query string)
query(ctx)                           # "format=json&verbose=1"
queryparams(ctx)                     # Dict("format"=>"json", "verbose"=>"1")

# Route params
param(ctx, :id)                      # String, "" if missing
param(ctx, :id, "default")           # String with default
param(ctx, Int, :id)                 # Union{Int, Nothing}
param(ctx, Float64, :score)          # Union{Float64, Nothing}

# Headers
header(ctx, "Content-Type")          # String, "" if missing
header(ctx, "X-Key", "default")      # String with default
hasheader(ctx, "Authorization")      # Bool

# Body
body(ctx)                            # String
rawbody(ctx)                         # Vector{UInt8}
content_type(ctx)                    # shortcut for Content-Type header

# Cookies
cookie(ctx, "session")               # String, "" if missing
cookies(ctx)                         # Dict{String,String}
```

### Middleware

Middleware lives in `ext/CiroMiddleware/` and is loaded explicitly:

```julia
using Ciro.Middleware
```

Middleware is a callable struct wrapping an inner handler. Julia monomorphizes the full chain — **zero virtual dispatch overhead**:

```julia
# Built-in
WithLogger(handler)                              # stdout access log
WithCORS(handler; origins="*", max_age=86400)    # CORS headers
WithTiming(handler)                              # X-Response-Time
WithRequestId(handler)                           # X-Request-Id
WithSecurityHeaders(handler)                     # OWASP security headers
WithRateLimit(handler; max_requests=100, window_seconds=60)

# Compose (outermost runs first)
stack = WithRateLimit(WithCORS(WithTiming(handler)); max_requests=1000)
```

**Custom middleware (the same pattern used by all built-in):**

```julia
struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(ctx::Context)::Response
    header(ctx, "Authorization") == "Bearer $(m.token)" || return fail(401)
    return m.handler(ctx)
end

# Use it
get!(router, "/admin", WithAuth(admin_handler, ENV["SECRET"]))
```

### Custom Logger

```julia
struct StderrLogger <: AbstractLogger end

Ciro.Interfaces.log!(::StderrLogger, level::Severity, msg::String) =
    println(stderr, "[$level] $msg")

server = Server(; router, logger=StderrLogger())
```

### Custom Error Catcher

```julia
struct JsonCatcher <: AbstractCatcher end

function Ciro.Interfaces.intercept(::JsonCatcher, err::Exception, req)
    @error "Unhandled" exception=err
    return json("""{"error":"internal_server_error"}"""; status=500)
end

server = Server(; router, catcher=JsonCatcher())
```

### Server

```julia
server = Server(;
    router,                          # required — any AbstractRouter
    logger   = NullLogger(),         # AbstractLogger (system events only)
    catcher  = DefaultCatcher(),     # AbstractCatcher (exception → Response)
    host     = "0.0.0.0",
    port     = 8080,
    backlog  = 8192,
    max_body_size     = 1_048_576,   # 1 MiB — requests exceeding this → 413
    shutdown_timeout  = 5.0,         # seconds to drain in-flight on shutdown
)

start!(server)   # blocks; handles Ctrl+C gracefully
stop!(server)    # signal shutdown from another task
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Server{Trie, NullLogger, DefaultCatcher}                       │
│  (fully monomorphized — no virtual dispatch at runtime)         │
├─────────────────────────────────────────────────────────────────┤
│  Middleware Chain: WithRateLimit{WithCORS{WithTiming{Handler}}}  │
│  → compiler inlines the entire composition into one function    │
├─────────────────────────────────────────────────────────────────┤
│  Trie Router                                                    │
│  • Priority: static > typed param > wildcard                    │
│  • Returns RouteResult (type-stable, no Union dispatch)         │
├─────────────────────────────────────────────────────────────────┤
│  Core (worker.jl + serialize.jl)                                │
│  • Zero-copy HTTP response serialization into pooled buffers    │
│  • Thread-per-core request dispatch with in-flight tracking     │
├─────────────────────────────────────────────────────────────────┤
│  Backend (io_uring)                                             │
│  • One ring per Julia thread (SO_REUSEPORT kernel load balance) │
│  • Multishot accept, ConnectionPool, BufferPool                 │
│  • lib/ciro.c → lib/ciro.so (future: BinaryBuilder JLL)        │
└─────────────────────────────────────────────────────────────────┘
```

## Modularity & Extension

Each module is a self-contained unit with clear interfaces:

| Module | Purpose | Extend by |
|--------|---------|-----------|
| `Backend` | io_uring async I/O | Implement `AbstractBackend` for alternative backends (epoll, kqueue) |
| `Interfaces` | Types + abstract contracts | Add new abstract types |
| `Router` | Trie-based dispatch | Implement `AbstractRouter` |
| `Middleware` | Request/response transforms (in `ext/`) | Any `struct{H}` with `(m::T)(ctx)::Response` |
| `Core` | HTTP server engine | Wrap or replace `start!` |

## Running Tests

```bash
# Build C library (required for Backend tests)
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring

# Run full test suite (405 tests + Aqua.jl + JET.jl quality checks)
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Benchmarks

Compare against **khttp** (production Rust HTTP server):

```bash
cd benchmarks/khttp && cargo build --release
./benchmarks/khttp/target/release/server &
julia --threads=auto --project=. benchmarks/ciro_bench.jl &
./benchmarks/run_bench.sh
```

Requires [`oha`](https://github.com/hatoo/oha): `cargo install oha`

## License

MIT
