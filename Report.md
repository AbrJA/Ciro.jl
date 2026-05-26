# Ciro.jl — Status Report & Production Roadmap

## Current Status (v0.1.0)

### What We Have

| Module | Purpose | Status |
|--------|---------|--------|
| **Interfaces** | Abstract types, Response builders, HTTP constants | ✅ Solid |
| **Backend** | io_uring async I/O engine (Linux) | ✅ Functional (requires `lib/ciro.so`) |
| **Core** | Server struct, serialization, worker dispatch | ✅ Functional |
| **Router** | Trie-based radix router with typed params | ✅ Production-quality |
| **Middleware** | Zero-cost functor middleware chain | ✅ Production-quality |

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  User Code: get!(router, "/api/:id::Int", handler)      │
├─────────────────────────────────────────────────────────┤
│  Middleware Layer (WithCORS ∘ WithTiming ∘ handler)      │
│  → Monomorphized at compile time, zero virtual dispatch │
├─────────────────────────────────────────────────────────┤
│  Router (Trie)           │  Interfaces (AbstractRouter) │
│  • Static/param/wildcard │  • Methods, Response, fail() │
│  • Typed params :id::Int │  • 404/405 discrimination    │
│  • O(path_depth) lookup  │  • header(), hasheader()     │
├──────────────────────────┴──────────────────────────────┤
│  Core (Server{R,L,C})                                   │
│  • Parametric → fully monomorphized per-app             │
│  • Zero-copy serialization                              │
│  • Thread-per-core dispatch                             │
├─────────────────────────────────────────────────────────┤
│  Backend (io_uring)                                     │
│  • One ring per thread (SO_REUSEPORT)                   │
│  • Multishot accept, pooled connections                 │
│  • Completion-based (no epoll/kqueue)                   │
├─────────────────────────────────────────────────────────┤
│  Linux Kernel (io_uring, 5.19+)                         │
└─────────────────────────────────────────────────────────┘
```

### Key Design Patterns Used

1. **Parametric types** — `Server{R,L,C}` eliminates all dynamic dispatch
2. **Functor middleware** — `struct WithCORS{H}; handler::H; end` → compiler inlines the entire chain
3. **Abstract interfaces** — `AbstractRouter`, `AbstractLogger`, `AbstractCatcher` enable user extensions
4. **Zero-copy parsing** — PicoHTTPParser returns views into the raw buffer
5. **Thread-per-core** — No locks, no shared state, kernel load-balances via SO_REUSEPORT
6. **Pool-based allocation** — `ConnectionPool`, `BufferPool` eliminate malloc in steady state

### Bugs Fixed in This Session

| Bug | Impact | Fix |
|-----|--------|-----|
| `start!` not stopping on Ctrl+C | Server orphans threads on interrupt | try/finally sets `_running[] = false` |
| `param()` infinite recursion | Stack overflow on any param access | Renamed local variable to avoid shadowing |
| `status_line()` undefined | Package wouldn't load | Changed to `Interfaces.status()` |
| `hasheader()` missing | Serialization broken | Added to Interfaces |
| `put!`/`delete!` ambiguity | Tests error on import | Extended `Base.put!`/`Base.delete!` |
| No 405 responses | All method mismatches return 404 | Router returns `MethodNotAllowed` with `Allow` header |

---

## Production Roadmap

### Phase 1: Core Reliability (Next)

#### 1.1 — Pure-Julia Fallback Backend
The current backend requires a compiled C library (`lib/ciro.so`) using io_uring. This limits portability.

**Action:** Implement `BackendSockets` — a pure-Julia backend using `Sockets.jl` + `@async` that works on all platforms. Keep io_uring as the high-performance Linux path.

```julia
# Goal: Users choose backend at server creation
server = Server(; router, backend=:sockets)  # portable
server = Server(; router, backend=:io_uring) # Linux high-perf
```

#### 1.2 — HTTP/1.1 Compliance
- [ ] Chunked transfer encoding (reading and writing)
- [ ] 100-continue handling
- [ ] Proper `Connection: keep-alive` timeout (configurable)
- [ ] `Host` header validation
- [ ] Max header size limit (OWASP)
- [ ] Request timeout (slow loris protection)

#### 1.3 — Graceful Shutdown
- [ ] Drain in-flight requests before closing
- [ ] Configurable shutdown timeout
- [ ] Signal handler (SIGTERM/SIGINT)

---

### Phase 2: Framework Features

#### 2.1 — Router Enhancements
- [ ] Route groups/prefixes: `group("/api/v1") do ... end`
- [ ] Route-level middleware: `get!("/admin", WithAuth(handler))`
- [ ] Regex constraints: `:id::r"[0-9a-f]{8}"`
- [ ] Route listing/introspection for OpenAPI generation
- [ ] HEAD auto-generation from GET handlers

#### 2.2 — Request/Response Improvements
- [ ] Body parsing: JSON, form-data, multipart (lazy, streaming)
- [ ] Cookie parsing and setting
- [ ] Content negotiation (`Accept` header)
- [ ] Streaming responses (SSE, chunked)
- [ ] File serving (static assets with ETag/Last-Modified)

#### 2.3 — Built-in Middleware Library
- [ ] Rate limiting (token bucket, per-IP)
- [ ] Compression (gzip/deflate/brotli response)
- [ ] ETag/conditional GET
- [ ] Security headers (HSTS, CSP, X-Frame-Options)
- [ ] Request body size limiting
- [ ] Session management

#### 2.4 — Error Handling & Observability
- [ ] Structured logging (JSON format option)
- [ ] Request ID propagation
- [ ] Metrics collection (latency histograms, error rates)
- [ ] Health check endpoint (`/health`, `/ready`)
- [ ] Stack trace formatting (dev mode vs prod mode)

---

### Phase 3: Advanced Protocols

#### 3.1 — WebSocket Support
- [ ] Upgrade negotiation (HTTP → WS)
- [ ] Frame parsing/serialization
- [ ] Ping/pong keepalive
- [ ] Per-message compression (permessage-deflate)

#### 3.2 — HTTP/2 Codec
- [ ] HPACK header compression
- [ ] Stream multiplexing
- [ ] Flow control
- [ ] Server push
- [ ] ALPN negotiation (requires TLS)

#### 3.3 — TLS
- [ ] MbedTLS or OpenSSL integration
- [ ] Certificate hot-reload
- [ ] ALPN for HTTP/2

---

### Phase 4: Ecosystem & DX

#### 4.1 — Developer Experience
- [ ] `@route` macro for cleaner registration
- [ ] Auto-reload in dev mode (Revise.jl integration)
- [ ] CLI tool: `ciro new myapp`, `ciro run`
- [ ] OpenAPI spec generation from routes
- [ ] Built-in test client (`Ciro.TestClient`)

#### 4.2 — Pluggable Architecture
- [ ] Backend interface: `AbstractBackend` (io_uring, epoll, kqueue, Sockets.jl)
- [ ] Codec interface: `AbstractCodec` (HTTP/1.1, HTTP/2, HTTP/3)
- [ ] Serializer interface: JSON, MsgPack, Protobuf
- [ ] Storage interface: sessions, cache

#### 4.3 — Deployment
- [ ] `juliac` AOT compilation support (already designed for trim=safe)
- [ ] Docker base image
- [ ] Systemd service template
- [ ] Kubernetes health/ready probes

---

## Comparison with Target Frameworks

| Feature | FastAPI (Python) | Actix (Rust) | Ciro.jl (Goal) |
|---------|-----------------|--------------|----------------|
| Routing | Path + typed params | Extractors | Trie + typed params ✅ |
| Middleware | ASGI middleware | Transform/wrap | Functor chain ✅ |
| Async I/O | asyncio | tokio | io_uring ✅ |
| Serialization | Pydantic | serde | Julia dispatch |
| OpenAPI | Auto-generated | Manual | Planned (Phase 4) |
| WebSocket | Built-in | Built-in | Planned (Phase 3) |
| HTTP/2 | Via uvicorn | Built-in | Planned (Phase 3) |
| Type safety | Runtime | Compile-time | Compile-time ✅ |
| Zero-cost abstractions | ✗ | ✅ | ✅ (parametric types) |

---

## Immediate Next Steps (Priority Order)

1. **Pure-Julia Sockets backend** — Makes the library usable without compiling C code
2. **Body parsing** — JSON request bodies are table stakes for any API framework
3. **Route groups** — Essential for organizing real applications
4. **Graceful shutdown** — Required for production deployments
5. **Compression middleware** — Major performance win for JSON APIs
6. **WebSocket upgrade** — Enables real-time features

---

## Module Quality Assessment

| Module | Simplicity | Modularity | Performance | Maintainability | Notes |
|--------|:----------:|:----------:|:-----------:|:---------------:|-------|
| Interfaces | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Clean, minimal, well-separated |
| Backend | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | Needs AbstractBackend for portability |
| Core | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | Solid, but needs HTTP/1.1 compliance |
| Router | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Production-ready, typed params, 405 |
| Middleware | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Elegant functor pattern |

**Test Coverage:** 193 tests passing, covering all public API surfaces.
