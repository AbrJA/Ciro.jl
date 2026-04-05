# Ciro.jl Changelog

## v0.4.0 — Full Feature Release

### New Modules

- **Query parsing** (`src/query.jl`): `query_params(req)`, `clean_path(req)`, `parse_query(qs)` with full URL percent-decoding and `+` as space
- **Body parsing** (`src/body.jl`): `body_string(req)`, `body_bytes(req)`, `parse_form(req)` for URL-encoded form data
- **Static file serving** (`src/static_files.jl`): `static_handler(root; prefix, index, max_age)` middleware with 30+ MIME types, `Cache-Control` headers, and directory traversal protection via `normpath`
- **WebSocket** (`src/websocket.jl`): Full RFC 6455 implementation — `ws_upgrade(req)` handshake with SHA-1/Base64, frame encode/decode for TEXT/BINARY/CLOSE/PING/PONG, masked frame support for client-to-server messages
- **Multi-process clustering** (`src/cluster.jl`): `cluster_server(app, port; workers)` using `fork()` + `SO_REUSEPORT` for kernel-level load balancing across processes. Graceful shutdown with SIGTERM to children.
- **TLS/HTTPS** (`src/tls.jl`): OpenSSL bindings via `ccall` — `TLSConfig(certfile, keyfile)` struct, SSL context creation, read/write/shutdown operations
- **HTTP/2 frames** (`src/h2.jl`): h2c frame parsing and encoding — `H2Frame` struct, SETTINGS/HEADERS/DATA/GOAWAY builders, minimal HPACK encoder (static table + literal without indexing)
- **Cross-platform fallback** (`src/compat.jl`): `fallback_server(app, port)` using Julia `Sockets` stdlib — works on macOS, Windows, and Linux without io_uring

### Router Enhancements

- **Route groups**: `group("/prefix", route1, route2, ...)` inside `@routes` to organize routes under a common prefix
- **Query string stripping**: Router automatically ignores `?key=value` during route matching — no changes needed to existing handlers
- **Module renamed**: `StaticRouter` → `Router` for clarity

### Server Improvements

- **Connection: close handling**: Server checks `Connection: close` header and closes the connection after the response instead of keep-alive
- **Request size limits**: Configurable `MAX_BODY_SIZE[]` (default 1 MB) — returns 413 if exceeded
- **Fixed io_uring + Julia signal interaction**: Removed `IORING_SETUP_COOP_TASKRUN` flag which caused CQE delivery failures due to Julia's GC signal handlers (SIGUSR2). Added EINTR retry loop in `wait_completion`
- **Type safety**: Fixed `Int32` vs `Int64` mismatch in `PendingWrites` when receiving fd values from C layer

### Middleware Additions

- **`RequestId`** — adds `X-Request-Id` header with unique thread-id + timestamp identifier
- **`Timing`** — adds `X-Response-Time` header with millisecond precision

### Dependencies

- Added `SHA` (for WebSocket handshake)
- Added `Base64` (for WebSocket Sec-WebSocket-Accept)
- Added `Sockets` (for cross-platform fallback server)

### Benchmarks

Ciro.jl vs Actix-web (Rust) — 128 connections, 10s, 4 threads:

| Endpoint | Ciro.jl | Actix-web | Ratio |
|----------|--------:|----------:|------:|
| Plaintext | 50,422 req/s | 57,437 req/s | 0.88x |
| JSON | 52,575 req/s | 50,509 req/s | 1.04x |
| Param route | 57,407 req/s | 51,312 req/s | 1.12x |

### Tests

- 197 tests across 45 test sets — all passing
- New test files: `query_test.jl`, `body_test.jl`, `websocket_test.jl`, `h2_test.jl`, `router_test.jl`, `middleware_test.jl`

---

## v0.3.0 — Production Hardening & juliac Compatibility

### Breaking Changes

- `Types.get_status_line(status)` renamed to `Types.status_line(status)` and now returns `String` instead of `Vector{UInt8}` — **eliminates allocation on every request** for common HTTP status codes
- `CORSConfig` struct removed; replaced with plain `CORS` function and `cors()` factory
- `Dates` stdlib dependency removed entirely

### Performance Improvements

- **Zero-allocation status lines**: Common HTTP status codes (200, 404, 500, etc.) return `const String` references. Previously each call allocated a new `Vector{UInt8}`. On a typical workload this eliminates ~1 allocation per request on the hot path
- **Direct buffer writes**: `serialize_response` now writes status lines directly via `_write_str!` instead of an intermediate `copyto!` from a Vector
- **Simplified Logger**: Removed per-request `IOBuffer` allocation; writes directly to stdout

### Bug Fixes

- **Fixed Logger `gmtime_r` buffer overflow**: The previous implementation used `NTuple{9,Cint}` (36 bytes) for `struct tm`, but on Linux x86_64 `struct tm` is 56 bytes (includes `tm_gmtoff` and `tm_zone` fields). This caused silent memory corruption. Now uses Julia's `Libc.TmStruct`/`Libc.strftime` which handles platform differences correctly
- **Fixed CORS shared header mutation**: Previous `CORS` middleware stored headers in a module-level closure that could accumulate entries across requests when used with `append!`. Now uses fresh header arrays per response

### juliac --trim=safe Compatibility

- Removed `using Libdl` (unused import that added unnecessary dependency surface)
- Added `__init__` in `Servers` module for runtime library validation
- CORS default middleware is now a plain function (no closure in module constant)
- All hot-path code uses concrete types with no `invokelatest` or `eval`
- `const String` status lines survive precompilation correctly (previous `Vector{UInt8}` in `Dict` did not)

### New Features

- `cors()` factory function for configurable CORS middleware
- `html()` response builder (added in 0.2.x, now documented)
- `Methods` enum exported for fast HTTP method comparison in user code

### API Additions

- `cors(; origins, methods, headers, max_age)` — returns a configured CORS middleware function
- `Ciro.Types.status_line(status::Int) -> String` — returns HTTP status line as const String

---

## v0.2.0 — Architecture Rewrite

### Core Architecture

- **Compile-time trie router**: `@routes` macro now builds a trie per HTTP method instead of linear if-else chains. Route matching is O(depth) instead of O(n)
- **Method-first dispatch**: Routes are grouped by HTTP method using `UInt8` tags instead of string comparison
- **io_uring C backend**: Custom C layer using `io_uring` with multishot accept, batched SQE submission, and zero-copy writes
- **Per-thread pools**: Connection objects and write buffers recycled via per-thread pools to minimize GC pressure
- **PendingWrites flat array**: Replaced `Dict{Ptr, Vector}` with flat array indexed by fd — eliminates hash allocation per request

### C Layer Optimizations

- `BUFFER_SIZE` increased from 2KB to 8KB (fewer partial reads)
- `SOCK_NONBLOCK` on server socket
- `TCP_NODELAY` on all accepted connections
- `IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SINGLE_ISSUER` with graceful fallback for older kernels
- Listen backlog increased from 4096 to 8192
- Compiled with `-O3 -march=native`

### Middleware System

- Middleware applied at compile-time via the `@routes` macro
- `Logger` middleware with sub-millisecond timing
- `CORS` middleware with preflight handling

### Type System

- `Response` struct with `Vector{Pair{String,String}}` headers
- `text()`, `html()`, `json()` response builders
- `Methods` enum for O(1) HTTP method lookup
- JSON support via package extension (`using JSON` activates `json()`)

---

## Future Roadmap

### Short Term

- **Query string parsing**: `req.query` accessor that lazily parses `?key=value&...` from the path
- **Request body parsing**: Built-in form-data and URL-encoded body parsers
- **Graceful shutdown**: Wake blocked threads when `stop_server()` is called (currently waits for timeout)
- **Connection: close handling**: Detect `Connection: close` header and don't queue reads after write
- **Request size limits**: Configurable max request body size to prevent DoS

### Medium Term

- **Static file serving**: Efficient `sendfile()` or `io_uring` splice for serving files from disk
- **WebSocket support**: Upgrade mechanism via io_uring
- **Route groups**: `@group "/api/v1" begin ... end` syntax for namespaced routes
- **BinaryBuilder JLL**: Distribute `libciro.so` as a JLL package for automatic installation
- **HTTP/2 support**: Via nghttp2 integration in the C layer

### Long Term

- **Clustering**: Multi-process support with shared socket for horizontal scaling beyond threads
- **TLS**: Native TLS support via OpenSSL/BoringSSL in the C layer
- **Observability**: OpenTelemetry-compatible tracing middleware
- **Windows/macOS**: Alternative backends (epoll, kqueue) for non-Linux platforms

### Performance Goals

- Target: ≥500K req/s for plaintext on modern hardware (comparable to Rust/Go frameworks)
- Target: ≤5μs p99 latency for simple handlers
- Target: Zero GC pauses under sustained load (all allocations in pooled buffers)

### Design Principles

1. **Allocation-free hot path**: Every allocation in the request lifecycle is a performance bug
2. **Compile-time over runtime**: Route dispatch, middleware composition, and type resolution happen at macro expansion time
3. **Minimal abstraction**: The C layer is a thin wrapper; Julia handles all application logic
4. **Thread-local everything**: No locks, no atomic operations on the hot path (per-thread pools, per-thread io_uring)
5. **juliac-first**: All code must compile with `--trim=safe` — no eval, no invokelatest, no dynamic dispatch on abstract types
