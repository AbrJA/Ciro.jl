# Ciro.jl — Architecture & Design Patterns Guide

> **Status:** canonical. This document replaces three prior, mutually inconsistent
> documents: the previously circulated `ARCHITECTURE.md`, and
> `docs/ARCHITECTURE_FEASIBILITY.md` + `docs/IMPLEMENTATION_PLAN.md`. Those described
> either aspirational features not present in code, or a multi-package ecosystem this
> project is not adopting (see §2). **§3** was verified against `src/` on
> `feat/refactor` and is kept as the historical baseline; **§3.4** records the current
> `dev` status. Everything in **§4 ("Target")** is proposed and open for review. If this
> document and the code disagree, the code is right and this document is stale — file an
> issue.
>
> Audience: maintainers and contributors. Update this doc in the same PR that changes
> an invariant it documents.

---

## 1. Goals and non-goals

### Goals

1. **Blazing-fast HTTP/1.1 on Linux** for ML model serving and high-concurrency REST
   APIs: low tail latency, high connection counts, minimal per-request overhead.
2. **Julia-native extensibility**: routing, handlers, error handling, and response
   construction live in Julia and are testable without the OS or the native backend.
3. **Small, auditable native layer**: C is used only where the OS demands it (io_uring
   syscalls, socket setup).
4. **Simple core, features as extensions**: the core does parse → route → respond.
   Streaming, compression, static files, TLS, metrics are opt-in, added later without
   redesigning the core.
5. **One package, community-extensible via traits and package extensions**, not a
   multi-package ecosystem (see §2).

### Non-goals (v1)

- HTTP/2, HTTP/3, WebSockets in the core.
- Built-in TLS termination.
- Cross-platform backends in the flagship path (Linux + io_uring first; a portable
  fallback comes once the byte-transport seam is frozen — see §4.5).
- A middleware stack / DI container. Extension happens through the traits in §5, not
  through a composable middleware pipeline.
- Splitting into multiple packages (`CiroBase`, `CiroCore`, ... ) — see §2.

### Hard constraints

- Julia ≥ 1.10, Linux kernel ≥ 5.19 for the default backend.
- `using Ciro` must work without the native library built (it warns, not errors, at
  `__init__`; this is already true today — see `Backend/Backend.jl`).
- Handlers are arbitrary Julia functions `Context -> Response`; the framework does not
  force async syntax on them.

---

## 2. Package shape: single package (decision)

Ciro stays a single package (`Ciro.jl` with internal modules) rather than splitting
into a `CiroBase`/`CiroCore`/`CiroRouter`/satellite-packages ecosystem, for the
foreseeable future (at least through v1 and likely well past it).

**Why:**
- A multi-package split freezes trait boundaries before they've been proven under
  load — the opposite of this document's own principle that interfaces should be
  frozen only once the features that depend on them justify it (§3, P9).
- Every extra package is extra precompilation and version-resolution cost for users
  who just want `Pkg.add("Ciro")`.
- The successful single-maintainer Julia web frameworks (HTTP.jl, Oxygen.jl, Genie.jl)
  are single packages with internal modules. Multi-package ecosystems earn their cost
  when the pieces have genuinely independent user bases and release cadences
  (Tables.jl, DifferentialEquations.jl) — Ciro's router, HTTP layer, and backend don't;
  they rev together.
- **Community extensibility is served by package *extensions* (weak deps), not package
  *splitting*.** A contributor can ship `CiroTLS.jl` or `CiroAuth.jl` as an independent
  satellite package depending on Ciro's frozen trait surface (§5), without Ciro itself
  being decomposed. This gets the plugin-ecosystem feel without the coordination tax.
- Keeping today's module boundaries clean (§4) preserves the *option* to extract a
  module into its own package later, mechanically, if a real need appears — you pay
  for that only if you exercise it.

`docs/ARCHITECTURE_FEASIBILITY.md` and `docs/IMPLEMENTATION_PLAN.md` should be
archived or deleted; their technical content (parametric structs, monomorphization,
AOT/`trim=safe` notes) is still useful and is folded into §6 below, but their
package-topology proposal is superseded by this section.

---

## 3. Today — verified against `src/` on `feat/refactor`

### 3.1 Module graph (as implemented)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Ciro (facade: includes in order, re-exports, precompile workload)    │
│                                                                       │
│  Interface   contracts & value types: Request/Response/Context,      │
│              Methods, RouteResult, AbstractRouter/Logger/Catcher/    │
│              Backend traits, NullLogger, DefaultCatcher (no I/O)     │
│      ↑                                                               │
│  Router      Trie: static > param > wildcard, groups, auto-HEAD,     │
│              typed params (:String/:Int/:Float64/:UUID)              │
│      ↑                                                               │
│  Core        Server{R,L,C} (parametric, monomorphized) + worker.jl    │
│              (HTTP handling FUSED with io_uring event dispatch) +     │
│              serialize.jl (response → bytes)                         │
│      ↑                                                               │
│  Backend     io_uring FFI: Engine/Connection/pools/event loop         │
│              (lib/ciro.c); exposed as a fairly complete low-level     │
│              async-IO API, not just an internal detail               │
└──────────────────────────────────────────────────────────────────────┘
```

This is close to the "Stages 0–2" picture in the prior architecture doc, **with one
important difference**: `Core/worker.jl` is not a thin HTTP-state-machine sitting on
top of a generic backend contract — it directly calls `Backend` primitives
(`queue_write!`, `acquire!(buf_pool)`, `ConnectionPool`, `PendingWrites`) inline inside
`_handle_read`/`_handle_write`. There is no `HTTP` module and no byte-transport seam
yet; that extraction is 100% still ahead of us (§4.1).

### 3.2 What is actually implemented (confirmed by reading the code and tests)

- Parametric, monomorphized `Server{R<:AbstractRouter, L<:AbstractLogger,
  C<:AbstractCatcher}` (`Core/server.jl`) — no dynamic dispatch on router/logger/
  catcher at the call site.
- Trie router with static/param/wildcard priority, `group!` prefixes, typed param
  parsing and validation, auto-HEAD, 405 with a computed `Allow` bitmask
  (`Router/Router.jl`).
- `RouteResult` as a closed three-outcome type (match/404/405) via field sentinels,
  avoiding a `Union`/sentinel-heavy return (`Interface/types.jl`).
- Zero-allocation, case-insensitive header lookup and `Connection` token matching
  (`Interface/request.jl`, `Core/worker.jl`'s `_hdr_key_eq_ci`/`_contains_token_ci`).
- `@noinline _invoke_handler` isolating `try/catch` from the hot dispatch path
  (`Core/worker.jl`).
- Response serialization into a pooled, auto-growing buffer with a status-line lookup
  table and duplicate-`Content-Length` avoidance (`Core/serialize.jl`).
- Connection/buffer pooling and pending-write tracking, keyed by fd, in `Backend/pool.jl`.
- Thread-per-core event loop (`run_eventloop_threaded!`), one `Engine`/ring per thread,
  `SO_REUSEPORT`-style acceptance via multishot accept.
- Graceful shutdown via an atomic `_running` flag + in-flight counter drain loop with a
  timeout (`Core/server.jl`).
- 450 lines of `Core` tests, 419 of `Router` tests, 507 of `Interface` tests, 188 of
  `Backend` tests — solid coverage of what exists (serialization, routing, dispatch,
  server construction).

### 3.3 What is **not yet** implemented, despite earlier claims

This is the gap that matters most before anyone (including future contributors) reads
a spec and assumes it's already true:

| Claimed as done (previous doc) | Actual state in `feat/refactor` |
|---|---|
| Incremental header parsing across partial reads | `PicoHTTPParser.parse_request(raw_data)` is called once on whatever a single read syscall returned (`worker.jl:_handle_read`). No accumulator, no "headers incomplete → rearm read" path. |
| Chunked transfer-encoding decode | Not present anywhere in `src/`. |
| Duplicate/conflicting `Content-Length`, `CL`+`TE`, obs-fold rejection | Not present. Whatever PicoHTTPParser itself rejects is the only defense; no framing-attack tests exist. |
| Header/body/idle deadlines (timeouts) | Not present. The only timeout in the codebase is the shutdown-drain deadline and the io_uring completion-wait poll interval — neither is a per-request deadline. |
| Pipelining (leftover bytes → parse next request immediately) | Not present; one read → one parse → one response per event. |
| Header-injection validation on `Response` construction (token names, no CR/LF/NUL in values) | Not present in `Interface/response.jl` — `Response` accepts any strings unchecked. |
| 36-test wire acceptance suite, 643 unit tests | Actual: ~1,564 lines across 5 test files, functional but not framing/attack-focused. |

None of this is a criticism of the code that exists — what's there is genuinely
well-built for what it covers. But a "production discipline" architecture doc that
states these as done, when they aren't, is actively dangerous: a contributor building
the async executor or a second backend on top of assumed framing correctness will
build on sand. **§4.2 makes closing this gap the literal first item of Stage 2.5,**
ahead of any new feature work, including ahead of the `HTTP`/`Backend` extraction if
the two end up competing for time.

### 3.4 Current status on `dev` (supersedes §3.1–3.3)

Everything in §3.3 is implemented, plus the `HTTP`/`Backend` extraction:

- Incremental parsing, pipelining, chunked bodies, limits/timeouts, and framing
  defenses (obs-fold, duplicate CL, CL+TE) all have wire coverage, as does
  header-injection validation (acceptance suite: 70 tests).
- Module graph is the §4.1 target:
  `Interface → Router → Runtime → HTTP → Backend (UringIO | SocketsIO) → Core`.
- `AbstractIO` byte seam (read/write/completion/shutdown/close/buffer/config) has two
  implementations, and the portable Sockets backend passes the same wire suite — the
  seam is proven, not just documented.
- Zero-copy request views: `Headers` is a lazy view, routing does not copy the path,
  and `_build_request` allocates ~480 B (from ~4 KB) under an allocation-budget test.
  `copy(req)`/`copy(ctx)` is the documented retention escape hatch.
- **Zero-allocation route params on the served path**: `route!` fills a reusable
  per-connection scratch with `Pair{Symbol,UnitRange{Int}}` ranges into the routed
  path (0 B for static and param routes under the allocation bench); `param` resolves
  them to views on demand and `copy(ctx)` materializes owned strings. The public
  `route` still returns owned strings so results are self-contained for manual use.
- `ServerConfig`/`ServerRuntime` split; one `stop!`; one dispatch pipeline shared with
  `Application` (parity-tested); `stop!`/SIGINT drain gracefully.
- **Async executor (v1.5)**: `AsyncExecutor(worker_threads, max_pending)` runs handlers
  on a bounded worker pool, so model inference cannot block a ring thread.
  `io_isasync`/`io_dispatch_async` extend `AbstractIO`; the deferred path copies the
  request before crossing the boundary (`copy-on-escape`), a per-connection generation
  drops replies for recycled connections, and `http_deliver_response` runs on the
  event-loop thread (UringIO drains a reply inbox in `on_tick`; SocketsIO uses one
  reply channel per connection task). Overload is shed with `503` + `Retry-After`;
  shutdown lets in-flight handlers finish until `shutdown_timeout`. Worker tasks run
  user code via `invokelatest` so handlers registered across `start!` cycles are
  visible (world-age safety); `run_eventloop!` submits after `on_tick`, so replies
  queued from worker threads are flushed even when no completion arrives.
- **Streaming/SSE**: handlers return `Stream` (`stream`/`sse` builders); the body
  runs on an executor worker with a `StreamWriter <: IO`. The HTTP layer frames
  `Transfer-Encoding: chunked` (raw when the user supplies `Content-Length`; body
  suppressed for HEAD), keeps exactly one flush in flight and acks the worker per
  chunk for backpressure, and `_finish_stream` resumes keep-alive/pipelining.
  Retirement (client disconnect, forced shutdown) fails the handshake and releases
  the worker; streaming requires `AsyncExecutor`.
- Gates: `Pkg.test()` → 789 passed, 0 failed; acceptance 97/97, also under
  `--check-bounds=yes`.

Still open: compiled routing, HTTP/2/TLS (see §4.2 and §9).

---

## 4. Target architecture (proposed, open for review)

### 4.1 Target module graph

```
┌──────────────────────────────────────────────────────────────────────┐
│  Interface   contracts & value types (unchanged in spirit)           │
│      ↑                                                                │
│  Router      routing (unchanged)                                      │
│      ↑                                                                │
│  Runtime     ONE pipeline: dispatch → executor → catcher              │
│      ↑                                                                │
│  HTTP        transport-agnostic connection state machine:             │
│              incremental parse, framing, limits, timeouts,            │
│              pipelining, response-writing contract (NEW MODULE)       │
│      ↑                                                                │
│  Backend     byte-transport implementations: io_uring (flagship),     │
│              Sockets (portable fallback) later                        │
│      ↑                                                                │
│  Core        composition: Config + RunState + workers + backend       │
│              (renamed/slimmed from today's Core, which loses its      │
│              HTTP-handling code to the new HTTP module)               │
└──────────────────────────────────────────────────────────────────────┘
```

The single structural move is: **extract everything in `worker.jl` that is HTTP
semantics (parsing, framing, limits, response writing) into a new `HTTP` module that
knows nothing about fds or io_uring, and leave `Backend` + a slimmed `Core` doing only
bytes.** Nothing else in the target list (zero-copy `Request`, async executor,
streaming, a second backend) can be built safely before this seam exists, because
right now there is nowhere to put "wait for more bytes" or "reject this malformed
frame" that isn't tangled with `queue_write!`/`ConnectionPool` calls.

### 4.2 Stage 2.5 — in priority order

1. **Close the gap in §3.3 inside the current fused code first** — **done** (§3.4):
   wire-level tests exist for timeouts, CL/TE conflict, obs-fold, and header-injection
   validation, so the `HTTP` extraction had a correctness baseline to preserve.
2. **Extract `HTTP`** with the write contract below, moving the now-hardened framing
   logic wholesale.
3. **Freeze the byte-transport seam** (`AbstractIO` — read/write/shutdown/timer
   callbacks; same shape as the prior proposal, unchanged, see below) so a second
   backend is possible without another redesign.
4. **Split `ServerConfig` from runtime state** (currently fields on one `Server`
   struct) to make per-worker state and future hot-reload cleaner.

```julia
# HTTP-facing write contract (implemented by a backend adapter)
write(conn, bytes) -> nothing        # may complete later
on_writable(conn)                    # backend tells HTTP to continue a partial write
close(conn)                          # graceful; flush pending first
```

### 4.3 Request lifecycle (target)

```
socket readable
   │
   ▼
Backend: read completion → bytes + connection handle
   │
   ▼
HTTP: append to rbuf
   ├─ headers incomplete?  → check max_header_bytes/timeout → rearm read
   ├─ headers done         → framing: CL / chunked / none
   │                          ├─ CL > max_body → 413 (+ close after flush)
   │                          ├─ CL+TE, duplicate CL, obs-fold → 400
   │                          └─ body incomplete → rearm read (body deadline)
   └─ message complete     → build Request (views) → Runtime.dispatch
                                │
                                ▼
                         Response (validated)
                                │
                                ▼
HTTP: serialize into pooled buffer → transport.write(conn, bytes)
   │
   ▼
Backend: submit write; on completion:
   ├─ partial write → resubmit remainder (backpressure)
   ├─ close requested → shutdown/finalize → release connection
   ├─ leftover bytes (pipelining) → parse next request immediately
   └─ else rearm read (idle deadline)
```

### 4.4 Memory and ownership rules (target)

1. **Julia owns buffers.** C receives pointers + lengths; lifetime guaranteed by
   `GC.@preserve` (or pool ownership) until completion. Today's C `conn_t` owns its own
   64 KiB read buffer *and* Julia copies into `rbuf` — double memory, a copy, to be
   removed.
2. **Views by default.** `Request`/`Context` reference the connection buffer; valid
   until the handler returns (synchronous v1). Give the view type a distinct name from
   a plain `SubArray`/`view` so `body(ctx)` (owned copy) and a hypothetical
   `unsafe_body(ctx)` (view) are visibly different at the call site — this is the
   detail most likely to cause a use-after-free-style bug if handled implicitly.
3. **Copy-on-escape** is the rule for the future async executor: crossing the executor
   boundary copies the request into a task-owned buffer.
4. **One close path** per connection: `shutdown()` → completion → `close()` → pool
   release → state release.
5. **Bounded pools**, size-based shedding, no unbounded fd-indexed tables (today's
   `PendingWrites` is fd-indexed and fragile across fd reuse — move it onto
   per-connection state owned by `HTTP`, per §4.1's `Core` slimming).

### 4.5 Cross-platform path (not started, sequenced deliberately last)

Once §4.2–4.4 land, a second backend becomes a matter of implementing `AbstractIO`
against blocking sockets + `Timer`, not a redesign:

- **Sockets** (portable fallback): Julia tasks + `Timer`; simplest, runs on macOS/
  Windows, no C. This should be the *first* non-Linux backend built, specifically
  because it's the acceptance test that the `HTTP`/`Backend` seam is genuinely
  transport-agnostic and not just documented as such.
- Keep `AbstractIO`'s *required* method surface satisfiable by a plain blocking-socket
  backend. Anything io_uring-specific (multishot accept, provided buffers) should be an
  optional capability check (e.g. `supports_multishot(io)::Bool`), not a required
  method — otherwise Sockets is forced to fake semantics it doesn't have.
- Reseau / libhv / Asio are later, additive options behind the same seam, only if a
  benchmark says the plain Sockets fallback isn't good enough for some deployment.

---

## 5. Extension points — the one page a third-party author needs

Today's traits (all in `Interface/types.jl`), and target additions once §4 lands.
This is the table that should ship at the top of `docs/EXTENDING.md` so contributors
don't have to read this whole document to add a router or a backend.

| Trait | Status | Required methods | Notes |
|---|---|---|---|
| `AbstractRouter` | **implemented** | `route(router, method::UInt8, path) -> RouteResult`; optionally `register!` and `route!(router, method, path, captures)` | `Trie` implements `route!` (zero-alloc served path via the connection scratch); the default `route!` delegates to `route`, so custom routers keep working unchanged. |
| `AbstractLogger` | **implemented** | `log!(logger, level::Severity, msg::String)` | System-level only — not per-request. |
| `AbstractCatcher` | **implemented** | `intercept(catcher, err::Exception, req) -> Response` | Must never leak internals by default (`DefaultCatcher` returns a generic 500). |
| `AbstractBackend` | **implemented, minimal** | `start_backend!(backend, handler_factory, port; kwargs...)`, `stop_backend!(backend)` | Today this is really "how to boot an io_uring engine," not a byte-level seam — see `AbstractIO` below, which will absorb the real per-connection contract. |
| `AbstractIO` (byte-transport seam) | **target, §4.2** | `accept_loop_started`, `on_connect`, `read`, `write`, `shutdown`, `close`, `timer` | This is the seam a second backend (Sockets, Reseau, ...) implements. Not to be confused with `AbstractBackend` above, which is the boot-time contract — naming these two consistently is an open decision (see §7). |
| `AbstractExecutor` | **implemented** | `execute!(executor, endpoint, ctx) -> Response` (`SyncExecutor`); `isasync`, `start_executor!`, `stop_executor!`, and the `Runtime.dispatch_async(..., reply)` path (`AsyncExecutor`) | Moves slow handlers (model inference) off the ring thread. Contract: the request is copied before crossing the boundary; `reply` is called exactly once, possibly from another thread; the adapter marshals it back to its event-loop thread; excess queued/running work → 503 + `Retry-After`. |

**Rule for every trait above:** it is documented with its full required-method list in
one place (this table), and a change to that list is proposed as an ADR, not a silent
edit — this is what "frozen" means throughout this document.

---

## 6. Julia design patterns catalog

Concrete techniques already in use, or to apply going forward, tied to *why* each one
matters here specifically (folded in from the feasibility doc, corrected where it
overstated things).

- **Parametric struct + monomorphization** (`Server{R,L,C}`, already in use): each
  concrete instantiation compiles to code with zero virtual dispatch on
  router/logger/catcher. Correct pattern, keep it — but note it only pays off if the
  *hot-path fields* are parametric; don't parametrize fields nobody calls per-request.
- **Trait-style abstract types + `function foo end` stubs** (`AbstractRouter`,
  `AbstractCatcher`, etc.): this is Julia's standard interface mechanism
  (`AbstractArray`, `IO`). Keep required-method lists documented (§5) since Julia has
  no compile-time interface check — an incomplete implementation only fails when a
  method is actually called.
- **Function barriers + `@noinline`** (`_invoke_handler`): isolates dynamically-typed
  or exception-heavy code from a `@inline`, type-stable hot loop. This is the same
  technique that should be applied to `RouteResult.handler::Any` (open decision A1,
  §7) — a `RouteResult{H}` parametric wrapper plus a function-barrier call at the
  dispatch site removes the last `Any` on the hot path without a new dependency
  (`FunctionWrappers.jl` is the alternative if a concrete field is worth the added rigidity).
- **Closed sum types via sentinel fields, not `Union`** (`RouteResult` encoding
  match/404/405 in one concrete struct): avoids `Union{Match,NotFound,...}` splitting
  and the type-instability that comes with it, at the cost of needing predicate
  functions (`matched`, `not_found`, ...) instead of pattern matching. Right call for a
  three-way hot-path result; would not scale to a result type with many more variants.
- **Package extensions (weak deps) for optional backends/features**, not new
  top-level deps: this is both the mechanism that supports §2's "single package, still
  extensible" decision, and how a *second* backend (Sockets) should ship if it ever
  needs a dependency Ciro's core doesn't (it likely won't, since `Sockets`/`Timer` are
  stdlib — but `Reseau`/`libhv` adapters would use this).
- **Zero-allocation string comparison via `codeunit` loops** (`_hdr_key_eq_ci`,
  `_contains_token_ci`): correct and already measured-good pattern for the hot path;
  the main risk is that every new header/token check gets hand-rolled ASCII-only —
  worth extracting into one small internal utility module so it's written once and
  reused, not reinvented per feature.
- **Thread-per-core, one engine per thread, no cross-thread sharing**: matches
  Julia's `Threads.@threads`/per-thread-state idiom and avoids the GC/lock interaction
  problems that come from sharing mutable native handles across threads. Keep this
  invariant explicit and Aqua/JET-checked if possible as the codebase grows.
- **`PrecompileTools.@compile_workload`** (already in `Ciro.jl`): exercises the real
  hot path (parse → route → dispatch → serialize) at precompile time. As new modules
  land (`HTTP`, `AbstractExecutor`), extend the workload to cover them — a precompile
  workload that only exercises Stage-0-era code stops being representative silently.
- **AOT (`juliac --trim=safe`) compatibility, if pursued**: the feasibility doc's
  warnings are valid technical content even though its package-topology conclusion is
  superseded — concretely, avoid `eval`/reflection in hot paths (already true), keep
  `RouteResult.handler` concrete where possible (ties back to A1), and treat any new
  trait's default methods as needing to be trim-safe before relying on them, not after.

---

## 7. Open decisions carried forward (trimmed to what's still undecided)

| ID | Decision | Recommendation |
|---|---|---|
| A1 | `RouteResult.handler::Any` — last `Any` on the hot path | Parametric `RouteResult{H}` + function barrier; measure before adding `FunctionWrappers.jl` |
| A2 | ~~`params::Vector{Pair{Symbol,String}}` allocates~~ | **Resolved (Stage 3)**: `route!` captures `Pair{Symbol,UnitRange{Int}}` into a per-connection scratch; `param` resolves views lazily, `copy(ctx)` materializes. Public `route` still returns owned strings for self-contained results. |
| D1 | Write contract shape (completion vs readiness) | Minimal completion-style contract (§4.2); readiness backends adapt by nonblocking-write-until-`EAGAIN` |
| E1 | Buffer ownership (double-copy today) | Julia owns read buffers; C reads into a caller pointer (§4.4) |
| E2 | `PendingWrites` fd-indexed, fragile across fd reuse | Attach to per-connection state owned by `HTTP` |
| F2 | SIGTERM not interceptable in Julia | Document SIGINT/`stop!` as the supported stop path (`systemd KillSignal=SIGINT`, `docker stop --signal=SIGINT`); do not build a wrapper process — out of scope for a library |
| J2 | `AbstractBackend` (boot contract) vs `AbstractIO` (byte seam) naming collision risk | Keep both, document the distinction in §5's table; do not merge them — they answer different questions ("how do I start" vs "how do I move bytes") |

Questions I'd most like a maintainer decision on:
1. Does §4.2's ordering (close the framing/timeout gap **before** extracting `HTTP`)
   match your priorities, or would you rather extract first and harden in place?
2. Is the Sockets-first cross-platform sequencing (§4.5) acceptable, i.e. no macOS/
   Windows work starts until the byte seam is frozen and proven by a Sockets backend?
3. Should `docs/ARCHITECTURE_FEASIBILITY.md` / `docs/IMPLEMENTATION_PLAN.md` be deleted
   outright, or kept in an `archive/` folder for their still-useful Julia-pattern notes
   (now folded into §6)?

---

## 8. Risks

- **Spec/implementation drift is the top risk right now**, demonstrated by this
  document's own §3.3. Mitigation: every claim of "implemented" in this doc must have
  a corresponding test name cited, and CI should fail if a doc section referencing a
  test file's line count goes stale (a cheap grep-based check is enough to start).
- **Latency of synchronous handlers** under slow inference: sync v1 blocks a ring
  thread. Mitigation: `AsyncExecutor` (v1.5, implemented) copies the request and runs
  the handler on a bounded worker pool. A hung handler still holds its own connection
  (and `stop_executor!` does not join hung workers); bounded by `shutdown_timeout`
  for connections, documented in `Server.start!`.
- **io_uring availability** (seccomp, old kernels, containers): mitigated by the
  portable Sockets fallback (§4.5) and fail-fast error messages (already partly done
  via the `_LIB` file-existence check in `Backend.jl`).
- **Two seam abstractions** (`AbstractBackend`, `AbstractIO`) confusing contributors:
  mitigated by the §5 table being the canonical, single reference.
- **What would invalidate this design:** measurements showing the sync+completion
  model loses to a task-per-connection portable backend at target concurrency; a hard
  requirement for TLS/HTTP2 in-core; or cross-platform becoming the *primary* goal
  before Linux performance is proven (would re-rank the roadmap in §4).

---

## 9. Roadmap

| Stage | Content |
|---|---|
| 0–2 ✅ | Parametric server, trie router, fused worker loop, connection/buffer pooling, thread-per-core event loop — verified in §3. |
| **2.5** ✅ | Closed the §3.3 gap with wire tests, extracted `HTTP` from `worker.jl`, froze the `AbstractIO` seam, added the portable Sockets adapter, split config from runtime state. |
| 3 ✅ | Zero-copy `Request` views, lazy `Headers`, copy-free routing, `copy(ctx)` escape hatch, request build ~480 B. Zero-allocation route params on the served path (`route!` + connection scratch; `route! static/param = 0 B`), `@inferred` guards. Pending: compiled routing (dispatch-table at `freeze!`). |
| 3.5 | Per-route limits, access log/metrics. |
| 4 | JLL packaging for the native lib, docs build, CI matrix. |
| v1.5 ✅ | Async executor (bounded, 503 shedding, copy-on-escape, both backends) and streaming/SSE on the same ownership boundary (chunked, backpressure, disconnect-safe). |
| v2 | Sockets backend ✅ (proves the seam), then Reseau/native alternatives only if benchmarks demand them. |

Rationale: every stage must leave the test suite green and must not require moving
code a later stage adds. The one deliberate reordering versus the previous document is
putting the §3.3 correctness gap ahead of the `HTTP` extraction — extracting a module
before its invariants are true just moves the same bugs to a new file.
