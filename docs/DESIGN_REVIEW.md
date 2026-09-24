# Ciro.jl — Design Review & Rethink

> Date: 2026-09-24
> Scope: full source audit of `src/`, `lib/ciro.c`, tests, packaging, CI, docs.
> Method: static review + measured runtime evidence (allocations, real-socket wire tests,
> fresh-checkout precompile test). All numbers below were reproduced on Linux, Julia 1.13.0.

---

## TL;DR

The architecture diagram is right; the implementation doesn't hold it up. The 582 passing
tests prove the unit surface, but the server fails on ordinary real-world requests
(split reads, pipelining). The failures are concentrated in exactly the areas the project's
own `DESIGN_LESSONS.md` warns about: wire correctness, limits, resource ownership, and
claims that no executable gate verifies.

---

## 1. What exists

| Module | Files / LOC | Role | Status |
|---|---|---|---|
| `Interface` | 7 files, ~430 L | Types, contracts, request/response helpers | Real, used |
| `Router` | 1 file, 328 L | Trie, typed params, groups, wildcard, HEAD auto-gen | Real, used |
| `Core` | 3 files, ~400 L | `Server`, serializer, io_uring worker | Real, used |
| `Backend` | 6 files, ~570 L | io_uring FFI, pools, event loop | Half-used |
| `Runtime` | 1 file, 231 L | `Application`, `AbstractTransport`, `FakeTransport` | Dead — `Server` never uses it |
| `lib/ciro.c` | 290 L | io_uring accept/read/write | Real |
| `lib/build_tarballs.jl` | 31 L | BinaryBuilder recipe | Never used; `.so` committed to git |
| docs | mixed | Iteration reports (ES), `DESIGN_LESSONS.md` | Not wired to Documenter (stock template) |

### Genuinely good — keep

- `RouteResult` ADT with allowed-method bitmask → clean 404/405 + `Allow`
  (`src/Interface/types.jl:89`).
- `freeze!` and registration-after-freeze guard.
- Zero-allocation serializer: measured **0 B** for `serialize_response!`, cached per-second
  `Date`.
- `@noinline` try/catch barrier around handler invocation (`src/Core/worker.jl:254`).
- Safe defaults: `NullLogger`, `DefaultCatcher` (no internals leak).
- `docs/DESIGN_LESSONS.md` is an excellent engineering spec. The gap is that the code does
  not meet it and no gate enforces it.

---

## 2. Measured evidence

### 2.1 Test suite

`Pkg.test()` → 582 pass (Julia 1.13.0, Linux). No wire-level, allocation, leak, or
concurrency tests exist.

### 2.2 Allocations per request

| Path | Bytes |
|---|---|
| `Request(raw_parser_request)` materialization | **2,968** |
| `route` static | 32 |
| `route` param | 144 |
| `_dispatch` static route (incl. handler) | 288 |
| `_dispatch` param route | 400 |
| `serialize_response!` | **0** |
| `queryparams` | 80 |

### 2.3 Wire tests (real sockets)

| Scenario | Result |
|---|---|
| Keep-alive, 2 sequential requests | OK |
| Headers split across two TCP writes | **`400 Bad Request`** |
| POST body split across two writes | **`400 Bad Request`** |
| Pipelined requests in one segment | **1 of 2 responses** (second lost) |
| HEAD on a GET route | `Content-Length: 0` (wrong; must equal GET entity length) |
| `Server(host="127.0.0.1")` | binds `0.0.0.0` (host ignored) |

### 2.4 Security probes

| Probe | Result |
|---|---|
| `redirect("/x\r\nX-Injected: evil")` | **CRLF header injection works** |
| `Methods.from_string("PUX")` / `"GEX"` | returns **PUT / GET** (only first two bytes compared) |

### 2.5 API / packaging probes

| Probe | Result |
|---|---|
| `stop!(app::Application)` | **`MethodError`** — `Runtime.stop!` shadowed by `Core.stop!` |
| Fresh checkout without `lib/ciro.so` | **package fails to precompile**: `could not load library .../lib/ciro.so` |

---

## 3. Flaws

### P0 — production blockers

1. **No incremental request buffering.** `_handle_read` parses whatever one `read()`
   returned (`src/Core/worker.jl:75-90`). PicoHTTPParser returns `nothing` for partial data
   and Ciro maps `nothing` → `400`. Any request split across TCP segments is rejected:
   TLS, slow clients, headers larger than one segment, any body not fully contained in one
   read.
2. **Pipelining loses requests.** Leftover bytes after the first request are discarded
   instead of being carried to the next parse.
3. **No timeouts, connection caps, or header limits.** No slowloris / header-timeout /
   idle-keepalive timeout, no `max_connections`. Every live connection pins a **64 KiB
   `conn_t`** (`lib/ciro.c:19`); the free pool retains up to 1024 connections per worker
   (`src/Backend/pool.jl:18`) → ~64 MiB/worker of idle buffers, plus 256×64 KiB
   `BufferPool` = 16 MiB/worker.
4. **SQE exhaustion is silent.** `get_sqe_submit_retry` returns `NULL` on failure and every
   C entry point returns `void` (`lib/ciro.c:30-35`). Julia never learns the operation was
   dropped → hung connections, no backpressure, no error.
5. **Pending-write bookkeeping leaks on error paths.** The `res < 0` branch in
   `_handle_http_event` closes the fd and recycles the conn but never `pop_pending!`s the
   buffer. `PendingWrites` is indexed by **fd** (`src/Backend/pool.jl:80`), so stale state
   can attach to a reused fd.
6. **CRLF/header injection.** No validation on emitted header values (redirect shown
   above; same for user headers).
7. **HEAD is wrong.** Auto-HEAD executes the GET handler and returns `Content-Length: 0`
   instead of the GET entity length (`src/Router/Router.jl:118-124`). It has side effects.
8. **Duplicate generics / two pipelines.** `Core.stop!` vs `Runtime.stop!`;
   `Runtime.submit!` vs `Backend.submit!`; `Core._dispatch` vs `Runtime.dispatch`.
   `stop!(app)` throws.
9. **Graceful shutdown is cosmetic.** `_in_flight` is incremented and decremented inside
   one synchronous read handler, so it is always 0 before `_drain` runs
   (`src/Core/server.jl:68-77`). No stop-accepting, no SIGTERM handling, `stop_backend!`
   is a no-op.
10. **Package cannot load without the native library.** `BUFFER_SIZE` executes a `ccall` at
    include time (`src/Backend/connection.jl:5`) and `_LIB` is a package-relative path.
    Breaks non-Linux, breaks precompile-cache misses, contradicts DESIGN_LESSONS 1.1
    ("core must load with no backend present").
11. **Dead config.** `Server.host` is ignored (C binds `INADDR_ANY`, `lib/ciro.c:85`);
    `backlog` is hardcoded 8192 in C; `max_body_size` is compared against `bytes_read`
    rather than `Content-Length`.
12. **The event loop never yields → in-process deadlock (confirmed).**
    `run_eventloop!` spins on `wait_completion` ccalls without `yield()`
    (`src/Backend/eventloop.jl:52-68`). When a worker lands on a thread the Julia
    scheduler needs, an in-process Julia client deadlocks mid-`write`, and a full Ciro
    server in-process blocks unrelated libuv operations (`listen`). Python clients work;
    in-process Julia clients hang nondeterministically. Stage 0 runs wire tests against a
    server subprocess; the real fix lands in Stage 1/2 (yield, dedicated threads, or
    scheduler-safe waits).

### P1 — performance and type stability

12. **`Any` fields on the hot path**: `RouteResult.handler::Any`
    (`src/Interface/types.jl:90`), `TrieNode.handlers::Dict{UInt8,Any}` and
    `wildcard::Dict{UInt8,Any}` (`src/Router/Router.jl:71-73`). One dynamic dispatch per
    request. `@inferred route` still passes because only the return type is annotated.
13. **`RouteResult.params::Vector{Pair{Symbol,String}}`** allocates per call (32 B static,
    144 B param) and `param(ctx, :x)` is a linear scan.
14. **`Request` eagerly copies everything** (~3 KB/request): every header to `String`, body
    copy, path/query re-split, while PicoHTTPParser already produced zero-copy
    `StringView`s.
15. **No allocation regression tests, no `@inferred` tests, JET is neutered.**
    `test/quality_test.jl:11-15` disables Aqua `ambiguities`/`piracies`;
    `JET.report_package(Ciro; target_modules=(Ciro,))` analyzes only the top module, not
    `Ciro.Core`, `Ciro.Router`, `Ciro.Backend`.
16. **`@spawn` is not thread-per-core.** No affinity and no scheduler headroom; loop tasks
    block their Julia threads in ccall.
17. **Router shape.** Recursive trie with `Dict{String,TrieNode}` and per-request
    allocations; not the compiled/radix shape used by high-throughput servers.

### P2 — API, packaging, hygiene

18. **Two competing frontends** (`Server` vs `Application`) with colliding exports.
19. **Base overloads** (`get!`, `put!`, `delete!` on routers) conflate collection
    semantics with route registration.
20. **Docs claims don't match code**: `cookie(ctx, ...)` documented but absent;
    "zero-cost middleware" not in core; `benchmarks/ciro_bench.jl:8` calls `param(:id)`
    (broken).
21. **`docs/make.jl` is the stock Example.jl template** (`modules = [Example]`, Example.jl
    repo URL) — docs CI cannot pass.
22. **`Project.toml` compat bug**: `Dates = "1.11.0"` while `julia = "1.10"` — stdlib
    compat blocks the declared floor.
23. **CI matrix tests Windows/macOS** where the package cannot even precompile.
24. **Hygiene**: `.so` committed, `Manifest.toml` committed, 200+ stale
    `compathelper/*` remote branches, root-level `server.jl` / `examples_server.jl` /
    `test_minimal.jl`, no `CHANGELOG` / `WORKLOG` despite the spec requiring them.

---

## 4. Patterns vs Julia state of the art

| Concern | Ciro today | Julia / HTTP SOTA | Gap |
|---|---|---|---|
| Handler storage | `Dict{UInt8,Any}`, `RouteResult.handler::Any` | Concrete-typed storage or function barrier; `FunctionWrappers.jl` for heterogeneous callables | High |
| Request model | Eager full copy | Zero-copy views + lazy parse (`StringViews`, streaming parsers) | High |
| Parsing | One-shot `parse_request(buf)` per read | Incremental state machine with `last_len`, leftover carry, pipelining | Critical |
| Config vs runtime | Mixed in `Server` with unused fields | Immutable validated `Config` + mutable `RunState` | High |
| Backend seam | `AbstractBackend` declared, never used; core cannot load without backend | Interface actually called by core; core loadable standalone | High |
| Shutdown | Atomic flag + fake counter | Stop-accept → drain with deadline → close; SIGTERM/SIGINT | High |
| Buffers | 64 KiB per conn in C, bounded vector pools | Provided-buffer rings / multishot recv, small reads, bounded send with backpressure | Medium |
| Errors | `AbstractCatcher` + `@noinline` try/catch | Same — already idiomatic | Low |
| Extension | Hand-rolled traits | Package extensions (`[weakdeps]` / `[extensions]`), capability traits | Medium |
| Router | Recursive trie, per-request allocs | Frozen compiled dispatch or radix; fast/generic parity tests | Medium |
| Quality gates | Aqua weakened, JET top-module only, no wire/alloc/leak tests | Full Aqua, JET baseline, `@inferred` + allocation budgets, acceptance suite | High |
| Packaging | `.so` in git, user compiles, BB script idle | `*_jll` artifact + `LibraryProduct`; fail fast on unsupported platforms | High |
| Naming | Two names per concept | One name per concept; no Base overloads; `*!` mutators | Medium |

**Conclusion:** the missing piece is not more patterns — it is enforced seams and
wire-level gates. Ciro has fakes (`FakeTransport`) and seams (`AbstractBackend`) that the
production path does not use, so the tests could not catch any P0 item.

---

## 5. Options with trade-offs

### Option A — Harden in place
Fix buffering/pipelining, limits/timeouts, SQE backpressure, CRLF, HEAD, `stop!`,
packaging; keep the module layout.
- **Pros:** fastest to a working server; existing tests stay useful; no API break.
- **Cons:** keeps two pipelines and dead abstractions; keeps `Any` dispatch and 3 KB
  request copies; likely a second refactor later.

### Option B — One pipeline + real seams (recommended)
Collapse `Runtime` and `Core` into one pipeline; make `Server` a thin transport adapter
over `AbstractBackend`; zero-copy request views with connection-owned buffers; incremental
parser; validated `Config` + per-thread `RunState`; JLL packaging; Linux-only fail-fast.
- **Pros:** matches `DESIGN_LESSONS.md`; one mental model; `FakeTransport` becomes the real
  core test surface; removes dead/duplicated code; unlocks the performance budget
  (Request 3 KB → ~0, route 0 alloc, no dynamic dispatch).
- **Cons:** 1–2 weeks of real work; 0.x API break (allowed and endorsed); requires careful
  buffer-lifetime design.

### Option C — Julia-native transport, io_uring optional
Build on `Sockets`/libuv with io_uring as an opt-in backend.
- **Pros:** all platforms; CI green; TLS ecosystem; larger audience.
- **Cons:** loses the niche; libuv scales worse; two backends to keep honest.

### Option D — Push protocol into C
Move parse + keep-alive state machine into `ciro.c`; Julia only handles dispatch.
- **Pros:** potential peak throughput; simpler Julia side.
- **Cons:** contradicts the modular-Julia goal; hardest to maintain; concentrates FFI
  ownership bugs in C.

**Recommendation: Option B, staged, starting with Option A's quick wins.** Do not start a
rewrite before adding wire tests that reproduce the P0 bugs.

---

## 6. Staged plan

**Stage 0 — Safety net (days)**
- Acceptance suite with raw sockets reproducing §2.3 (split headers/body, pipelining, HEAD
  length, CRLF, host bind, fd leaks).
- Make `using Ciro` loadable without the native lib (lazy `dlopen` in `__init__`).
- CI: Linux-only backend; fix `Dates` compat; restore full Aqua; JET with
  `target_defined_modules=true`.

**Stage 1 — Correctness core**
- Per-connection read buffer + incremental parse with `last_len`, leftover carry,
  pipelining; `400` only on genuine parse errors.
- Validated `ServerConfig`: `max_header_bytes`, `header_timeout_ms`, `body_timeout_ms`,
  `idle_timeout_ms`, `max_connections`, `max_body_size`; enforce from `Content-Length`.
- SQE-full handling: return status from C; never silently drop.
- Fix HEAD, CRLF rejection, `host`/`backlog` wiring or removal.

**Stage 2 — One pipeline, real seams**
- Single dispatch/invoke path; one `stop!`; one `submit!`; delete or wire `Runtime`;
  make `Server` use `AbstractBackend`; real graceful shutdown.

**Stage 3 — Performance and type stability**
- Zero-copy `Request`; remove `Any` from routing; allocation budgets in CI; `@inferred`
  tests; optional compiled routing after `freeze!`.

**Stage 4 — Production packaging**
- JLL via BinaryBuilder; extensions for optional integrations; real docs build;
  `CHANGELOG.md` + `WORKLOG.md`; prune branches and iteration docs.

**Simplicity principle:** keep an abstraction only when a second implementation exists (or
a fake actively exercises it). Otherwise delete it and re-add it when proven. This alone
removes `Runtime`, the dead `IOUringBackend`, and the duplicate generics.

---

## 7. Decisions (2026-09-24)

1. **Parser** — optimize the C-backed `PicoHTTPParser.jl` with an allocation-free,
   headers-first incremental API; Ciro owns buffering and framing in Julia. A pure Julia
   parser is a later, separate effort behind an `AbstractParser` seam, validated by
   differential fuzzing against the C parser.
2. **Concurrency** — synchronous dispatch in v1 (zero-copy, simple). Bounded async
   executor with load shedding in v1.5 for slow inference.
3. **Streaming** — SSE/chunked responses ship in v1.5, but the v1 write path is designed
   for it from the start: per-connection pending-write owner object, deque of buffers,
   unsent-bytes cap.
4. **Packaging** — Linux + JLL artifact via BinaryBuilder; fail fast on unsupported
   platforms. No `.so` or `Manifest.toml` in git.

## 8. Target architecture (v1)

```
Interface   contracts and value types (no I/O)
    ↑
Router      trie routing (no I/O)
    ↑
Runtime     ONE pipeline: dispatch + executor + catcher (+ middleware hooks), no I/O
    ↑
HTTP        per-connection incremental parse/framing state machine (no OS handles)
    ↑
Backend     io_uring FFI, connection objects, pools (OS)
    ↑
Core        Server: ServerConfig + RunState, worker loop, transport adapter, shutdown
```

Rules:

- `using Ciro` must succeed without the native library; `Backend` loads lazily
  (`dlopen` on first `Server` start).
- `Runtime` is the single dispatch path. `Core._dispatch` is deleted; `Server` calls
  `Runtime.dispatch`.
- `HTTP` knows nothing about `Runtime`; `Core` orchestrates parse → dispatch → write.
- `AbstractBackend` is actually called by `Core`, not decorative.
- One `stop!`, one `submit!`, one name per concept.
- Abstractions stay only while a second implementation or an active fake exercises them.

### Parser contract (implemented in `PicoHTTPParser.jl` branch `feat/incremental-head-api`)

```julia
hb = HeaderBuffer(max_headers)        # one per worker thread, reused
status = parse_request_head!(hb, buf, last_len)  # :partial | :done | :error, zero alloc

# on :done (all zero-alloc when consumed in place):
method = head_method(hb, buf)         # BufferView into buf
path   = head_path(hb, buf)
hlen   = head_header_len(hb)          # header block length
minor  = head_minor_version(hb)
n      = header_count(hb)
get_header(hb, buf, "host")           # lazy case-insensitive scan, no materialization

# chunked decode: in-place, explicit state, pipelining-safe
result = decode_chunked!(decoder, buf)
result.status                         # :partial | :done | :error
decoded_data(result, buf)             # decoded bytes compacted to buffer front
leftover_data(result, buf)            # bytes after the terminal chunk (next request)
```

Status: 82/82 parser tests pass, including steady-state zero-allocation assertions.
`ChunkedResult` changed shape (breaking), version bumped to 0.3.0.

`Request` in Ciro is then a view bundle over the connection-owned buffer
(`method`/`target`/`path`/`body` + header block offset), with lazy
`header`/`queryparams` parsing. No `String` copies on the dispatch path.

## 9. Stage 0 status — branch `feat/stage0-safety-net`

- [x] Wire acceptance suite (`test/acceptance_test.jl`): raw libc-socket client,
      server subprocess; 14 assertions pass and 6 P0 defects are pinned with
      `@test_broken` (split headers, split body, body > read buffer, pipelining,
      HEAD entity length, CRLF injection). Each flips to a hard failure when fixed,
      forcing promotion to `@test`.
- [x] `using Ciro` works without `lib/ciro.so` (lazy `_LIB_AVAILABLE`, lazy
      `buffer_size()`); backend still fails fast at `start!`.
- [x] CI: Linux-only job that installs `liburing-dev` and builds `lib/ciro.so`;
      docs job disabled until Stage 4.
- [x] Full Aqua restored (ambiguities, piracies, compat bounds) and JET now targets all
      submodules.
- [x] `Project.toml`: stdlib compat fixed (`Dates = "1.11.0"` blocked the declared
      Julia 1.10 floor); `Sockets`/`Test` extras declared for the test target.
- [x] Test run: 599 passed, 6 broken, 0 failed (Julia 1.13, Linux).

## 10. Stage 1 status — correctness core

- [x] Incremental per-connection state machine: `rbuf` accumulation, `last_len` head
      parsing, leftover carry/pipelining, retired connections (no stale completions).
- [x] Validated limits/timeouts: `max_header_bytes`, `header_timeout_ms`,
      `body_timeout_ms`, `idle_timeout_ms`, `max_connections`; 431/413 answers,
      deadline sweep closes idle/partial connections.
- [x] `host`/`backlog` wired through to the native bind; `IOUringBackend` used by
      `Server` (the `AbstractBackend` seam is real).
- [x] SQE exhaustion returns status; no silent drops.
- [x] HEAD carries the GET entity's `Content-Length`; CR/LF/NUL rejected in headers.
- [x] Ownership fixes: fd-keyed close flag reset on fd reuse; `shutdown()` before close
      so a pending io_uring read cannot hold the socket open.
- [x] Parser: `parse_request_head!` allocation-free, offset-based views that survive
      buffer growth (`PicoHTTPParser.jl` `07215a5`, `ccd41c6`).
- [x] All six Stage 0 `@test_broken` pins promoted to `@test`.
- [x] Test run: **614 passed, 0 failed** (incl. full Aqua + JET and 29 wire tests).
- [ ] CI green — blocked on releasing `PicoHTTPParser 0.3.0` (Ciro `Pkg.develop`s the
      local checkout today).
- [ ] Chunked transfer-encoding wire tests; per-route body limits; access logging.
