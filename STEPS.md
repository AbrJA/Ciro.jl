# Ciro.jl v0.1.0 — Final Optimization Steps

## Design Decisions (Rationale)

### `RouteResult.handler::Any` — Keep as-is
The trie stores heterogeneous handlers (closures, structs, functions). Any container
for them MUST erase the type. `FunctionWrappers.jl` adds a dependency for ~30ns
savings per dispatch — negligible vs network I/O (~100μs+). **Not worth it.**

### `Base.get!` / `Base.put!` / `Base.delete!` — Keep piracy
Alternatives (`route_get!`, non-exported `Router.get!`) all degrade the user API.
The piracy is harmless because signatures don't overlap with Dict methods (first arg
is `Trie`, not `AbstractDict`). Aqua piracy check is disabled. `register!` exists
for users who prefer explicit non-piracy calls. **Keep.**

### `header()` returns `String(v)` — Keep the allocation
PicoHTTPParser returns StringViews into the raw connection buffer. Returning a view
to the user is UNSAFE — the buffer is reused after the handler returns. Copying
(`String(v)`) ensures the returned value is safe to store. The hot-path
(`_wants_close`) already avoids this via `_header_eq`. **Keep for safety.**

### `path()` calls `String(req.path)` — Keep the conversion
Same reason as `header()`: the StringView from PicoHTTPParser points into the
connection buffer. We must copy once for safety. The optimization is to avoid
ADDITIONAL allocations (_split_path), not this initial safe copy.

---

## Implementation Steps

### 1. Rename `module Interfaces` → `module Interface`
Julia convention: module name matches folder name (singular). Update all
`using ..Interfaces` / `import ..Interfaces` references across the codebase.

### 2. Remove cookies from core
Cookies don't belong in a minimal HTTP core — future `CiroCookies.jl` package.
Remove `cookies()`, `cookie()`, `setcookie()` from `request.jl` and exports.

### 3. Fix `_wants_close` — use `_hdr_key_eq` (case-insensitive)
Current code checks "Connection" and "connection" separately. Proxies may send
"CONNECTION" or mixed case. Use the existing `_hdr_key_eq` from request.jl for
proper case-insensitive matching.

### 4. Remove redundant `GC.@preserve` in worker.jl
`set_pending!(pending, fd, out_buf)` already roots the buffer until write
completion. The `GC.@preserve` block only protects during `queue_write!` ccall
but the buffer must live longer. The `pending` reference handles this.
The `GC.@preserve` is misleading — remove it.

### 5. Zero-alloc route matching (eliminate `_split_path` in hot path)
Replace `_split_path(path) → Vector{String}` with inline segment iteration
during trie traversal. Use `SubString{String}` views for segment extraction
(zero-alloc, works with `Dict{String}` via content-based hash/isequal).
Keep `_split_path` only for `register!` (startup, not hot path).

### 6. Response body `Union{String, Vector{UInt8}}`
Eliminate one memcpy for string responses. `text("Hello")` currently copies
String→Vector{UInt8}→output_buffer (2 copies). After: String→output_buffer
(1 copy). Both types support `pointer()` and `sizeof()`/`length()` for
zero-copy serialization.

### 7. Add `Date` header (RFC 9110 §6.6.1)
Every response MUST include a Date header. Cache the formatted date string
and refresh every second (standard approach in nginx, Go). Thread-safe via
immutable String replacement.

### 8. Add `Connection: close` in response
When the server decides to close (client sent `Connection: close`), include
the header in the response per RFC 9110. Simple push to response.headers
before serialization.

### 9. Add PrecompileTools workload
Reduce first-request latency (~2s JIT → <100ms). Precompile the hot path:
route registration, request dispatch, response serialization.

### 10. Max header limits (DoS protection)
Reject requests with excessive headers (>100 headers or >8KB total header
size). Simple check after PicoHTTPParser parse — no architectural change.

---

## Not Implementing (v0.2.0+)

- **Request timeout handling** — requires io_uring IORING_OP_TIMEOUT, significant
  C library changes
- **Response streaming** — needs chunked transfer encoding + io_uring integration
- **StringViews as direct dependency** — not needed; we work with AbstractString
  generically, and safety requires String copies at the API boundary anyway
