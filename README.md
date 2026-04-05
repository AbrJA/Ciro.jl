# Ciro.jl

High-performance HTTP framework for Julia, built on Linux `io_uring` with compile-time route dispatch.

## Features

- **io_uring backend** — Linux kernel async I/O with multishot accept, zero-copy writes, and batched submissions via a thin C layer
- **Compile-time trie router** — `@routes` macro generates a trie per HTTP method; route matching is O(depth) with no runtime data structures
- **Route groups** — `group("/prefix", ...)` for organizing routes under a common prefix
- **Query string parsing** — `query_params(req)` with URL-decoding, stripped from routing automatically
- **Body parsing** — `body_string(req)`, `body_bytes(req)`, `parse_form(req)` for form data
- **Multi-threaded** — one `io_uring` instance per Julia thread with `SO_REUSEPORT` kernel load balancing
- **Multi-process clustering** — `cluster_server()` forks workers with `SO_REUSEPORT` for maximum throughput
- **Per-thread object pools** — connection objects and write buffers are recycled to minimize GC pressure
- **Zero-allocation hot path** — status lines are `const String` references; response serialization uses `unsafe_copyto!` into pooled buffers
- **Connection management** — `Connection: close` header handling, request size limits (413 response)
- **Static file serving** — `static_handler()` middleware with MIME type detection, cache headers, directory traversal protection
- **WebSocket support** — RFC 6455 handshake, frame encode/decode, ping/pong/close
- **HTTP/2 frames** — h2c frame parsing, HPACK encoding, SETTINGS/HEADERS/DATA/GOAWAY frames
- **TLS support** — OpenSSL integration via `TLSConfig` for HTTPS
- **Observability** — `RequestId` and `Timing` middleware for request tracing
- **Cross-platform fallback** — `fallback_server()` using Julia's `Sockets` stdlib for non-Linux systems
- **juliac --trim=safe compatible** — no `eval`, no `invokelatest`, all dispatch is static
- **Middleware pipeline** — compose Logger, CORS, RequestId, Timing, or custom middleware at compile time
- **JSON extension** — `using JSON` activates `json()` response builder via Julia's package extension mechanism

## Requirements

- **Linux** with kernel ≥ 5.19 (for multishot accept)
- **liburing** development headers (`apt install liburing-dev` or equivalent)
- **Julia** ≥ 1.10 (1.12+ for `juliac` compilation)
- **GCC** for building the C library

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

### Build the C library

```bash
cd ~/.julia/packages/Ciro/*/lib   # or your local clone
gcc -shared -fPIC -O3 -march=native -o ciro.so ciro.c -luring
```

Or from the repository root:

```bash
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring
```

## Quick Start

```julia
using Ciro

function index(req)
    return text("Hello from Ciro!")
end

function get_user(req, id)
    return text("User: " * String(id))
end

@routes App begin
    ("GET", "/") => index
    ("GET", "/user/:id") => get_user
end

start_server(App(), 8080)
```

Run with multiple threads:

```bash
julia --threads=auto --project=. app.jl
```

## API Reference

### Defining Routes

Use the `@routes` macro to define an application with compile-time route dispatch:

```julia
@routes MyApp begin
    middleware(Logger)
    middleware(CORS)
    ("GET",    "/")           => index_handler
    ("POST",   "/users")      => create_user
    ("GET",    "/users/:id")  => get_user
    ("PUT",    "/users/:id")  => update_user
    ("DELETE", "/users/:id")  => delete_user
    ("GET",    "/files/*")    => serve_file    # wildcard catch-all
end
```

**Supported HTTP methods:** GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS

**Route parameters** (`:param`) are passed as `SubString` arguments to handlers in declaration order:

```julia
# Route: ("GET", "/user/:uid/post/:pid")
function get_post(req, uid, pid)
    return text("User $(String(uid)), Post $(String(pid))")
end
```

**Wildcard routes** (`*`) match any remaining path:

```julia
# Route: ("GET", "/static/*")
function serve_static(req)
    # req.path contains the full path
    return text("Serving: " * String(req.path))
end
```

### Request Object

The `req` parameter is a `PicoHTTPParser.Request` with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `req.method` | `StringView` | HTTP method (`"GET"`, `"POST"`, etc.) |
| `req.path` | `StringView` | Request path (`"/users/42"`) |
| `req.headers` | `Vector{Pair}` | Request headers as key-value pairs |
| `req.body` | `SubArray{UInt8}` | Request body bytes |

Convert `StringView` to `String` with `String(req.method)`.

### Response Builders

```julia
# Plain text (Content-Type: text/plain; charset=utf-8)
text("Hello"; status=200)

# HTML (Content-Type: text/html; charset=utf-8)
html("<h1>Hello</h1>"; status=200)

# JSON (requires `using JSON` to activate extension)
# Content-Type: application/json; charset=utf-8
json(Dict("key" => "value"); status=200)

# Raw Response with custom headers
Response(201, "Created")
Response(200, [
    "Content-Type" => "application/xml",
    "X-Custom" => "value",
], Vector{UInt8}("<data/>"))
```

### Query Parsing & Body Parsing

```julia
using Ciro

function search(req)
    params = query_params(req)        # Dict{String,String}
    q = get(params, "q", "")
    return text("Search: $q")
end

function submit(req)
    form = parse_form(req)            # URL-encoded form data
    name = get(form, "name", "")
    return text("Hello, $name!")
end

function upload(req)
    raw = body_bytes(req)             # Vector{UInt8}
    return text("Received $(length(raw)) bytes")
end
```

### Route Groups

```julia
@routes ApiApp begin
    middleware(Logger)
    ("GET", "/") => index_handler

    group("/api/v1",
        ("GET",  "/users")     => list_users,
        ("POST", "/users")     => create_user,
        ("GET",  "/users/:id") => get_user,
    )
end
```

### Static File Serving

```julia
# Serve files from ./public when path starts with /static
@routes App begin
    middleware(static_handler("./public"; prefix="/static", max_age=3600))
    ("GET", "/") => index_handler
end
```

### WebSocket Upgrade

```julia
function ws_handler(req)
    return ws_upgrade(req)  # Returns 101 Switching Protocols
end

# Frame encoding
frame = ws_encode_text("Hello WebSocket!")
close = ws_encode_close(UInt16(1000), "Bye")
```

### Multi-Process Clustering

```julia
# Fork N workers, each with its own io_uring instance
cluster_server(App(), 8080; workers=Sys.CPU_THREADS)
```

### Observability Middleware

```julia
@routes App begin
    middleware(RequestId)    # Adds X-Request-Id header
    middleware(Timing)       # Adds X-Response-Time header
    middleware(Logger)       # Logs to stdout
    ("GET", "/") => index_handler
end
```

### Cross-Platform Fallback

```julia
# For non-Linux systems (macOS, Windows)
fallback_server(App(), 8080)
```

### Middleware

Middleware wraps handlers with `(req, next) -> Response` signature:

```julia
function Logger(req, next)
    # Called before handler
    response = next(req)    # calls the next middleware or handler
    # Called after handler
    return response
end
```

**Built-in middleware:**

- `Logger` — logs `[timestamp] METHOD /path -> status (duration)` to stdout
- `CORS` — permissive CORS with `Access-Control-Allow-Origin: *`
- `cors(; origins, methods, headers, max_age)` — configurable CORS factory

```julia
# Default permissive CORS
@routes App begin
    middleware(CORS)
    ("GET", "/api/data") => get_data
end

# Custom CORS
my_cors = cors(origins="https://example.com", max_age=3600)
@routes App begin
    middleware(my_cors)
    ("GET", "/api/data") => get_data
end
```

**Custom middleware example:**

```julia
function AuthMiddleware(req, next)
    # Check authorization header
    for (k, v) in req.headers
        if String(k) == "Authorization"
            return next(req)
        end
    end
    return Response(401, "Unauthorized")
end

@routes App begin
    middleware(AuthMiddleware)
    ("GET", "/protected") => protected_handler
end
```

### Server

```julia
# Start on port 8080 using all available threads
start_server(App(), 8080)

# Stop gracefully
stop_server()
```

## JSON Support

JSON serialization is provided via a package extension. Load `JSON` to activate:

```julia
using Ciro
using JSON  # activates json() function

function api_handler(req)
    return json(Dict(
        "status" => "ok",
        "users" => [
            Dict("id" => 1, "name" => "Alice"),
            Dict("id" => 2, "name" => "Bob"),
        ]
    ))
end
```

## Compiling with juliac

Ciro is designed to be compatible with `juliac --trim=safe` (Julia 1.12+):

```julia
# app.jl
using Ciro

function hello(req)
    return text("Hello, World!")
end

@routes App begin
    ("GET", "/") => hello
end

function main()
    start_server(App(), 8080)
end

main()
```

```bash
# Build the native binary
juliac --trim=safe --output-exe ciro_app app.jl

# Make sure libciro.so is accessible
export LD_LIBRARY_PATH=/path/to/lib:$LD_LIBRARY_PATH
./ciro_app
```

**Requirements for juliac:**
- Julia 1.12+
- `libciro.so` must be at the compiled path or on `LD_LIBRARY_PATH`
- No `eval`/`invokelatest` in your handler code

## Running Tests

```bash
# Build the C library first
gcc -shared -fPIC -O3 -march=native -o lib/ciro.so lib/ciro.c -luring

# Run tests
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Benchmarking

### Ciro.jl vs Actix-web (Rust) — 128 concurrent connections, 10s duration, 4 threads/workers

| Endpoint | Ciro.jl (req/s) | Actix-web (req/s) | Ratio |
|----------|----------------:|------------------:|------:|
| `GET /` (plaintext) | **50,422** | 57,437 | 0.88x |
| `GET /json` | **52,575** | 50,509 | 1.04x |
| `GET /user/42` (param) | **57,407** | 51,312 | 1.12x |

Ciro.jl achieves **88–112%** of Actix-web throughput — competitive with a mature Rust framework.

**Run benchmarks yourself:**

```bash
# Start Ciro server
julia --threads=auto --project=. benchmarks/ciro_bench.jl

# Start Actix-web server
cd benchmarks/rust_server && cargo build --release && ./target/release/bench_server

# Run oha
oha -z 10s -c 128 --no-tui http://127.0.0.1:8080/
oha -z 10s -c 128 --no-tui http://127.0.0.1:8081/
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  @routes macro (compile-time)                       │
│  ┌───────────────────────────────────────────────┐  │
│  │ Parse routes → Build trie per method →        │  │
│  │ Generate dispatch(::AppType, req) function    │  │
│  └───────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│  Julia Threads (one per core)                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │ Thread 1 │ │ Thread 2 │ │ Thread N │  ...       │
│  │ io_uring │ │ io_uring │ │ io_uring │            │
│  │ pool     │ │ pool     │ │ pool     │            │
│  └──────────┘ └──────────┘ └──────────┘            │
├─────────────────────────────────────────────────────┤
│  C Layer (lib/ciro.c → ciro.so)                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ io_uring: multishot accept, batched submit,   │  │
│  │ SO_REUSEPORT, TCP_NODELAY, SOCK_NONBLOCK      │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Request lifecycle:**
1. `io_uring` multishot accept → new connection fd
2. TCP_NODELAY set on fd → queue read
3. Read completion → `PicoHTTPParser.parse_request` (zero-copy)
4. `Methods.from_string` (UInt8 tag) → trie dispatch → handler
5. `serialize_response` into pooled buffer → queue write
6. Write completion → recycle buffer → queue next read (keep-alive)

## Project Structure

```
src/
  Ciro.jl          # Main module, re-exports public API
  types.jl         # Request, Response, text/html/json builders, Methods enum
  query.jl         # URL query string parsing with urldecode
  body.jl          # Request body parsing (string, bytes, form data)
  middleware.jl     # Logger, CORS, RequestId, Timing middleware
  router.jl        # @routes macro, compile-time trie dispatch, route groups
  server.jl        # io_uring event loop, connection pools, response serialization
  static_files.jl  # Static file serving with MIME detection
  websocket.jl     # WebSocket RFC 6455 (handshake, frames, encode/decode)
  cluster.jl       # Multi-process clustering via fork + SO_REUSEPORT
  tls.jl           # TLS/HTTPS via OpenSSL bindings
  h2.jl            # HTTP/2 frame parsing and encoding (h2c)
  compat.jl        # Cross-platform fallback server (Julia Sockets stdlib)
ext/
  CiroJSON/        # JSON extension (activated by `using JSON`)
lib/
  ciro.c           # C io_uring engine (compile to ciro.so)
test/
  runtests.jl
benchmarks/
  ciro_bench.jl    # Ciro benchmark server
  rust_server/     # Actix-web comparison server
  run_bench.sh     # Automated benchmark script
examples/
  app.jl           # Full example with JSON, Logger, params
  simple_server.jl  # Minimal example
  static_app.jl    # Example with middleware
```

## License

MIT

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions?query=workflow%3ACI+branch%3Amain)

A high-performance REST API framework for Julia built on Linux's `io_uring` for asynchronous I/O.

## Features

- **High Performance**: Built on `liburing` for efficient async I/O with zero-copy operations
- **Multithreaded**: Automatic load balancing across threads using `SO_REUSEPORT`
- **Zero Allocations**: Optimized response generation with buffer pooling
- **Simple API**: Express-like routing with path parameters

## Requirements

- Linux kernel 5.19+ (for multishot accept)
- liburing development headers (`apt install liburing-dev`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the C library:
```bash
cd ~/.julia/packages/Ciro/xxx/lib
gcc -shared -fPIC -o ciro.so ciro.c -luring
```

## Quick Start

```julia
using Ciro

# Define routes
Ciro.get("/") do req, params
    Ciro.text("Hello, World!")
end

Ciro.get("/users/:id") do req, params
    Ciro.json(Dict("user_id" => params["id"]))
end

Ciro.post("/data") do req, params
    Ciro.text("Received: $(String(req.body))")
end

# Start server (uses all available threads)
Ciro.start_server(8080)
```

## API

### HTTP Methods

```julia
Ciro.get(handler, path)
Ciro.post(handler, path)
Ciro.put(handler, path)
Ciro.delete(handler, path)
Ciro.patch(handler, path)
Ciro.options(handler, path)
Ciro.head(handler, path)
```

### Response Helpers

```julia
Ciro.text(body; status=200)      # Plain text response
Ciro.json(data; status=200)      # JSON response
Response(status, body, headers)  # Custom response
```

### Middleware

```julia
Ciro.use(Ciro.Logger)  # Add logging middleware
```

## Performance Tips

1. **Start Julia with multiple threads**: `julia -t auto`
2. **Pre-compile before benchmarking**: Run a few requests first
3. **Use static strings** in responses when possible

## Benchmarking

```bash
# Simple benchmark
wrk -t4 -c1000 -d30s http://localhost:8080/

# High concurrency
wrk -t8 -c10000 -d30s http://localhost:8080/
```

## License

MIT License - see [LICENSE](LICENSE)
