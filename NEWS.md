# Ciro.jl Changelog

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
