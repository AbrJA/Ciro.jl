# Ciro.jl

High-performance HTTP framework for Julia, built on Linux `io_uring` with zero-cost middleware composition and type-stable routing.

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions)

## Features

- **io_uring backend** — Linux kernel async I/O, multishot accept, SO_REUSEPORT, zero-copy writes
- **Radix trie router** — O(path depth) dispatch, typed params (`:id::Int`), wildcards, route groups
- **Zero-cost middleware** — functor chain, fully monomorphized by the compiler (no virtual dispatch)
- **Type-stable routing** — `RouteResult` encodes match/404/405 without `Union` return types
- **Thread-per-core** — one `io_uring` ring per Julia thread, no cross-thread locking
- **Pool-based allocation** — `ConnectionPool`, `BufferPool` eliminate malloc in steady state
- **HEAD auto-generation** — HEAD handlers auto-derived from GET (RFC 9110 §9.3.2)
- **Cookie utilities** — `cookie()`, `cookies()`, `setcookie()` with all standard attributes
- **Body utilities** — `body()`, `rawbody()`, `content_type()`
- **Query params** — `queryparams()`, `query()`, `path()`
- **Parametric server** — `Server{R,L,C}` fully monomorphized per application
- **Custom middleware** — zero-boilerplate functor pattern (any callable struct works)
- **Custom error catcher** — `AbstractCatcher` intercepts all exceptions safely
- **Graceful shutdown** — drains in-flight requests before exit

## Requirements

- **Linux** with kernel ≥ 5.19 (multishot accept)
- **liburing** development headers (`apt install liburing-dev`)
- **Julia** ≥ 1.10
- **GCC** for the C library

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the C library:

```bash
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring
```

## Quick Start

```julia
using Ciro

router = Trie()
get!(router, "/",          req -> text("Hello, World!"))
get!(router, "/user/:id",  req -> json("""{"id":$(param(:id))}"""))
post!(router, "/echo",     req -> text(body(req)))

server = Server(; router, port=8080)
start!(server)
```

Run with all CPU threads:

```bash
julia --threads=auto --project=. app.jl
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
head!(router,    "/path", handler)   # HEAD auto-generated from GET if not set
options!(router, "/path", handler)
```

#### Route Parameters

```julia
# Untyped — any segment matches
get!(router, "/users/:id",         req -> text(param(:id)))

# Typed — router rejects non-matching segments at match time (no handler called)
get!(router, "/users/:id::Int",    req -> text("id=$(param(Int, :id))"))
get!(router, "/price/:n::Float64", req -> text("price=$(param(Float64, :n))"))
get!(router, "/token/:t::UUID",    req -> text(param(:t)))

# Multiple params
get!(router, "/posts/:post_id::Int/comments/:cid::Int",
     req -> json("""{"post":$(param(Int,:post_id)),"comment":$(param(Int,:cid))}"""))

# Wildcard
get!(router, "/files/*", req -> text("serving: $(path(req))"))
```

#### Route Groups

```julia
group!(router, "/api/v1") do g
    get!(g,    "/users",       list_users)
    post!(g,   "/users",       create_user)
    get!(g,    "/users/:id",   get_user)
    put!(g,    "/users/:id",   update_user)
    delete!(g, "/users/:id",   delete_user)

    # Nested groups
    group!(g, "/admin") do a
        get!(a, "/stats", admin_stats)
    end
end
```

### Handlers

A handler is any callable that accepts a `Request` and returns a `Response`:

```julia
# Function
function greet(req)
    name = param(:name, "World")
    return text("Hello, $name!")
end

# Lambda
handler = req -> json("""{"ok":true}""")

# Callable struct (same pattern used by all built-in middleware)
struct Greeter; prefix::String; end
(g::Greeter)(req) = text("$(g.prefix) $(param(:name))!")
```

### Response Builders

```julia
text("Hello"; status=200)                    # text/plain; charset=utf-8
html("<h1>Hi</h1>")                          # text/html; charset=utf-8
json("""{"key":"value"}""")                  # application/json; charset=utf-8
json("""{"created":true}"""; status=201)
redirect("/login")                           # 302 Found
redirect("/permanent"; status=301)           # 301 Moved Permanently
fail(404, "Not Found")                       # text/plain with status
fail(400)                                    # empty body

# Raw response with custom headers
Response(200, ["X-Custom" => "value", "ETag" => "\"abc\""], Vector{UInt8}("data"))
```

### Request Utilities

```julia
# Path and query
path(req)                          # "/users/42" (no query string)
query(req)                         # "q=julia&page=2"
queryparams(req)                   # Dict("q"=>"julia","page"=>"2")

# Route params (set by router during dispatch)
param(:id)                         # String, "" if missing
param(:id, "default")              # String with default
param(Int, :id)                    # Union{Int,Nothing}
param(Float64, :price)             # Union{Float64,Nothing}

# Headers
header(req, "Content-Type")        # String, "" if missing
header(req, "X-Key", "default")    # String with default
hasheader(req, "Authorization")    # Bool

# Body
body(req)                          # String copy of body
rawbody(req)                       # Vector{UInt8} copy
content_type(req)                  # header(req, "Content-Type")

# Cookies
cookie(req, "session")             # String, "" if missing
cookie(req, "token", "none")       # String with default
cookies(req)                       # Dict{String,String} of all cookies
```

### Response Utilities

```julia
header(resp, "Content-Type")       # String, "" if missing
hasheader(resp, "ETag")            # Bool

# Set-Cookie header builder
push!(resp.headers, setcookie("session", "abc123";
    max_age=3600, httponly=true, secure=true, samesite="Lax"))
```

### Middleware

Middleware is a callable struct wrapping an inner handler. The compiler
monomorphizes the full chain — there is zero virtual dispatch overhead.

**Built-in middleware:**

```julia
WithLogger(handler)                          # stdout access log
WithCORS(handler)                            # CORS with Access-Control-Allow-Origin: *
WithCORS(handler; origins="https://x.com", max_age=3600)
WithTiming(handler)                          # X-Response-Time header
WithRequestId(handler)                       # X-Request-Id (unique per request)
WithSecurityHeaders(handler)                 # HSTS, CSP, X-Frame-Options, nosniff
WithRateLimit(handler; max_requests=100, window_seconds=60)  # token bucket per IP

cors(; origins="*", max_age=86400)           # factory: cors()(handler)
```

**Composing middleware:**

```julia
# Outermost runs first on every request
stack = WithRateLimit(
            WithSecurityHeaders(
                WithCORS(
                    WithRequestId(
                        WithTiming(
                            WithLogger(router))))))

server = Server(; router=stack, port=8080)
```

**Route-level middleware** (applied only to specific routes):

```julia
get!(router, "/admin", WithAuth(admin_handler, secret_token))
```

**Custom middleware:**

```julia
struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(req)
    header(req, "Authorization") == "Bearer $(m.token)" || return fail(401, "Unauthorized")
    return m.handler(req)
end
```

### Custom Error Catcher

```julia
struct MyCatcher <: AbstractCatcher end

function intercept(::MyCatcher, err::Exception, req)
    @error "Request failed" exception=err
    return json("""{"error":"internal_server_error"}"""; status=500)
end

server = Server(; router, catcher=MyCatcher(), port=8080)
```

### Custom Logger

```julia
struct StderrLogger <: AbstractLogger end

Ciro.Interfaces.write(::StderrLogger, level::Severity, msg::String) =
    println(stderr, "[$level] $msg")

server = Server(; router, logger=StderrLogger(), port=8080)
```

### Server

```julia
server = Server(;
    router,                          # required — any AbstractRouter
    logger   = NullLogger(),         # optional — any AbstractLogger
    catcher  = DefaultCatcher(),     # optional — any AbstractCatcher
    host     = "0.0.0.0",
    port     = 8080,
    backlog  = 8192,
    max_body_size     = 1_048_576,   # 1 MiB — requests larger than this → 413
    shutdown_timeout  = 5.0,         # seconds to drain in-flight requests on stop
)

start!(server)   # blocks; handles SIGINT gracefully
stop!(server)    # signal graceful shutdown from another thread
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Server{Trie, NullLogger, DefaultCatcher}           │
│  (fully monomorphized — no virtual dispatch)        │
├─────────────────────────────────────────────────────┤
│  Middleware Chain (functor composition)             │
│  WithRateLimit{WithCORS{WithTiming{Trie}}}          │
│  → compiler inlines the entire chain                │
├─────────────────────────────────────────────────────┤
│  Trie Router                                        │
│  • Static > typed param > wildcard priority         │
│  • Returns RouteResult (type-stable — no Union)     │
│  • 404: result.allowed == 0x00                      │
│  • 405: result.allowed != 0x00 → Allow header       │
├─────────────────────────────────────────────────────┤
│  Core (worker.jl + serialize.jl)                    │
│  • Zero-copy response serialization (pooled buffers)│
│  • In-flight counter for graceful shutdown          │
├─────────────────────────────────────────────────────┤
│  Backend (io_uring)                                 │
│  • One ring per Julia thread (SO_REUSEPORT)         │
│  • Multishot accept, ConnectionPool, BufferPool     │
│  • lib/ciro.c → lib/ciro.so                         │
└─────────────────────────────────────────────────────┘
```

**Request lifecycle:**
1. `io_uring` multishot accept → connection fd acquired from `ConnectionPool`
2. Read completion → `PicoHTTPParser.parse_request` (zero-copy into pooled buffer)
3. Body size check (→ 413 if exceeded)
4. `Methods.from_string` (UInt8 tag) → trie dispatch → `RouteResult`
5. `not_found(result)` → 404 | `method_not_allowed(result)` → 405 with `Allow` header
6. `result.handler(req)` → `Response`
7. `serialize_response!` into `BufferPool` buffer → `queue_write!`
8. Write completion → buffer returned to pool → next read queued

## Project Structure

```
src/
  Ciro.jl              # Top-level module — re-exports all public API
  Interface/
    Interface.jl       # Types, response builders, utilities, abstract interfaces
  Router/
    Router.jl          # Trie router, route groups, typed params, RouteResult
  Middleware/
    Middleware.jl      # WithLogger, WithCORS, WithTiming, WithRequestId,
                       # WithSecurityHeaders, WithRateLimit
  Core/
    Core.jl            # Server module
    server.jl          # Server struct, start!, stop!, graceful shutdown
    serialize.jl       # Zero-copy response serialization
    worker.jl          # io_uring event loop, HTTP dispatch
  Backend/
    Backend.jl         # io_uring bindings module
    types.jl           # Connection, CompletionEvent, EventType
    engine.jl          # Engine lifecycle, queue_* operations
    connection.jl      # Connection struct, fd accessors
    pool.jl            # ConnectionPool, BufferPool, PendingWrites
    eventloop.jl       # run_eventloop_threaded!
lib/
  ciro.c               # C io_uring engine (compile → ciro.so)
test/
  runtests.jl
  interfaces_test.jl
  router_test.jl
  middleware_test.jl
  core_test.jl
  backend_test.jl
benchmarks/
  ciro_bench.jl        # Ciro benchmark server (mirrors khttp routes)
  khttp/               # Rust khttp comparison server (port 3000)
  run_bench.sh         # Automated benchmark: Ciro vs khttp
docs/
  ARCHITECTURE_FEASIBILITY.md
  IMPLEMENTATION_PLAN.md
  INFRA_BLOCKED_FEATURES.md
server.jl              # Feature showcase — run to explore all capabilities
```

## Benchmarks

Compare against **khttp** (a production Rust HTTP server):

```bash
# 1. Build khttp
cd benchmarks/khttp && cargo build --release

# 2. Start khttp (port 3000)
./benchmarks/khttp/target/release/server &

# 3. Start Ciro (port 8080)
julia --threads=auto --project=. benchmarks/ciro_bench.jl &

# 4. Run comparison
./benchmarks/run_bench.sh
```

Requires [`oha`](https://github.com/hatoo/oha): `cargo install oha`

## Running Tests

```bash
# Build C library first
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring

# Run tests (201 tests)
julia --project=. -e 'using Pkg; Pkg.test()'
```

## What Cannot Be Done Without Backend Changes

Some HTTP/1.1 features require changes to the C `io_uring` layer. See
[docs/INFRA_BLOCKED_FEATURES.md](docs/INFRA_BLOCKED_FEATURES.md) for full
analysis of: chunked transfer encoding, 100-continue, request timeouts,
keep-alive idle timeout, and SSE/WebSocket streaming.

## License

MIT
