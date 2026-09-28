# Design Lessons & Engineering Standards

> **Origin.** Every rule below was validated (or learned the hard way) while taking
> Mongoose.jl — a Julia HTTP/WS framework over a C library — through two adversarial
> production-readiness campaigns. Ciro.jl targets a different backend (io_uring,
> thread-per-core) but the same problem space, so this document is adopted as the
> project's engineering standard. It is a checklist, not prose: if a PR violates a
> rule here, it needs a measured reason.
>
> License note: Mongoose.jl is GPL-2.0; Ciro.jl is MIT. **Copy patterns, never code.**

---

## 0. The non-negotiables (short list)

1. **Type stability on every hot path.** No `Any` returns, no untyped fields, no
   `::Function` struct fields in stored callables. Verify with `@inferred` and JET.
2. **Zero non-const globals.** All mutable state lives in a `RunState`/runtime struct
   reachable from the server object.
3. **Every resource-owning path has a close path that provably closes the OS resource**
   (fd, ring entry, task, buffer) — and a test that proves it.
4. **Backpressure everywhere data can outrun the consumer** (streaming, queues, uploads).
5. **Limits are explicit, validated at construction, and safe by default**
   (body, headers, connections, frame sizes, timeouts).
6. **Every bug fix lands with a wire-level regression test**, not just a unit test.
7. **Four gates before any commit**: unit/main suite, streaming/threaded variant,
   acceptance/wire suite, Aqua + JET (+ docs build when public API moved).
8. **One commit per task**, with a WORKLOG entry and a CHANGELOG line when user-visible.

---

## 1. Architecture patterns

### 1.1 Layer the code; make the core standalone and replaceable

Proven layering (strict include order, each layer only depends downward):

```
Interface (types, contracts, no I/O)
    ↑
Router / Core (parsing, dispatch, serialization — no OS handles)
    ↑
Runtime (transport-independent application loop; FakeTransport lives here)
    ↑
Backend (io_uring / epoll / …)
```

Rules:

- The **core layer must load with no backend/FFI present** — it is the
  replaceability seam and the fastest test surface.
- Include order is strict and documented in the module file. Structs used as
  parametric fields must be defined before the composing struct.
- A facade module re-exports the public surface; internal modules stay internal
  (Ciro already does this with `Interface`/`Core`/`Router`/`Runtime`/`Backend`).

### 1.2 Protocols over inheritance: abstract type + functions + loud fallbacks

```julia
abstract type AbstractBackend end
function start_backend! end              # no default: missing method = loud error

# Optional capabilities get no-op/`false` defaults so HTTP-only users work:
can_stream(::AbstractBackend) = false
```

- **Required** operations: declare the generic and let a missing method throw
  `MethodError` (or add an explicit fallback that throws a descriptive error).
- **Optional** operations: provide defaults (`nothing`, `false`, `0`) so a minimal
  implementation is usable.
- Never branch on `isa` in the hot path when a type parameter or trait call works.

### 1.3 Capability traits (not symbol lookups)

```julia
can_tls(::AbstractBackend) = false
can_stream(::AbstractBackend) = false
can_ws(::AbstractBackend) = false
```

- One predicate per capability; discoverable by grep/completion; typo = `MethodError`.
- Do **not** use `supports(backend, Val(:tls))`: worse discoverability, runtime
  symbol errors, no method-completion, and rare in idiomatic Julia.
- One name per layer: the backend says `can_ws`; the router says `has_ws_routes`.

### 1.4 Parametric composition with build-time barriers

```julia
mutable struct Application{R<:AbstractRouter, E<:AbstractExecutor,
                           L<:AbstractLogger, C<:AbstractCatcher,
                           T<:AbstractTransport}
    router::R; executor::E; logger::L; catcher::C; transport::T
end
```

- Store collaborators as type parameters; dispatch resolves statically.
- Concentrate type instability at **construction time** (`_build_app`) with a
  function barrier, so every runtime method sees concrete types.
- Executor choice is a type, not a runtime `if`:
  `executor isa SyncExecutor ? … : …` must be a one-time branch (or a small
  `@inline` dispatcher), never per-request.

### 1.5 Split immutable config from mutable runtime

```julia
struct ServerConfig            # built once, validated, never mutated
    max_body_bytes::Int
    header_timeout_ms::Int
    body_timeout_ms::Int
    max_header_bytes::Int
    stream_buffer_bytes::Int
    max_connections::Int
    # …
end

mutable struct RunState        # everything that changes while running
    running::Threads.Atomic{Bool}
    connections::Dict{…}
    streams::Dict{…}
    conn_times::Dict{…}
    # …
end
```

- Config reads go through `server.config.*`; runtime mutations through
  `server.runtime.*`. No `getproperty` forwarding hacks.
- **Validate in the constructor** (`> 0`, ranges, mutually consistent), not at
  request time. Config errors are startup errors.

### 1.6 Router protocol + an explicit result ADT

```julia
struct Matched{H}         handler::H; params::…; end
struct NotFound end
struct MethodMismatch     allowed::UInt16; end   # bitmask, RFC 9110 §15.5.6
```

- `route(router, method, path)::RouteResult` — never overload the meaning of
  `nothing`/`false`.
- `MethodMismatch` carries the allowed-method bitmask so the 405 can emit `Allow`.
- Registration after `start!` throws (all mutation surfaces: routes, middleware,
  errors, services, hooks, mounts).
- `freeze!` closes the table; if you compile a fast path (exact dict + ordered
  param patterns), the generic path must stay available and be pinned equal by a
  parity matrix (compiled vs generic results).
- Decide and document auto-HEAD explicitly (Ciro should pick one; Mongoose
  removed it deliberately: HEAD on a GET-only route is 405 and `Allow` omits HEAD).

### 1.7 Middleware as callables; scope as metadata; bake the stack

```julia
struct WithAuth{H}; handler::H; token::String; end
(m::WithAuth)(ctx) = header(ctx, "Authorization") == "Bearer $(m.token)" ?
                     m.handler(ctx) : fail(401, "unauthorized")
```

- Any callable `(ctx) -> Response` / `(ctx, next) -> Response` is middleware; no
  required base type, but provide an abstract type for the framework's own
  middleware so they can be tagged.
- Route/group-scoped middleware = **metadata on the endpoint** (tuple field), not
  a second dispatch mechanism. Resolution order: global → group → route.
- Global stack: bake into an immutable tuple at registration; the per-request
  pipeline walks the tuple with a cursor and one closure (`Next`) — no vector
  concatenation, no per-request allocation.
- Registration must be build-phase only; freeze the stack when the server starts.

### 1.8 Typed DI, not a context dict

- Put services in a `NamedTuple` reachable from the request/context with a
  concrete type; access through a `Val`-parameterized accessor so it is
  type-stable and allocation-free:

```julia
service(ctx, Val(:db))   # resolved statically; no Dict, no boxing
```

- Avoid `Dict{Symbol,Any}` context bags in the hot path. Lazily allocate only for
  user-defined scratch state.

### 1.9 Testing doubles are first-class, in the core

- Ship a `FakeTransport` (drives the whole pipeline with no OS I/O) and a
  `FakeExecutor` (queued jobs + deterministic `run!`), and export both.
- They make unit tests fast, deterministic and backend-free — and they force the
  seams to stay honest.
- If a fake is hard to write, the abstraction is wrong.

---

## 2. Performance patterns (Julia)

### 2.1 Type stability and function barriers

- Parameterize every struct that holds callables or containers of heterogeneous
  values (`Endpoint{H}`, `WSEndpoint{M,O,C}`, `Application{…}`).
- Prefer multiple dispatch to `if x isa T`; if a branch is unavoidable, put it
  behind a function barrier so the body is compiled for concrete types.
- Drop `@nospecialize` from public registration APIs: it pessimizes the stored
  types. Specialize instead.
- Run JET on the package; keep the baseline at zero new errors.

### 2.2 Allocation budgets + regression guards

- Maintain a `bench/` script that asserts per-request allocation/ns budgets
  (`BENCH_ASSERT=1` in CI) **and** unit tests that assert allocations and
  `@inferred` for the hot path.
- Example proven baselines (Mongoose, 64B fixed route, single thread):

  | Scenario | Budget |
  |---|---|
  | frozen fixed route | ≤ 200 B / ~250 ns |
  | frozen param route | ≤ 550 B |
  | + CORS + ETag | ≤ 1.1 KB |
  | method parse | 0 B / ~4 ns |
  | DI access with services | ≤ 250 B |

- Record baselines in the docs; a regression is a test failure, not a review note.

### 2.3 Byte-level hot paths

- Parse the method (and other fixed tokens) with a single bounded compare
  (`memcmp`/`Base.bytesequal`-style), not `String(...) ==` allocation.
- Keep headers as an ordered `Vector{Pair{String,String}}`-backed type with
  case-insensitive `get`/`haskey` and a **zero-cost ASCII fast path**; expose
  `pairs`/`keys`/`values` as views, `pairs` zero-copy.
- Serialize header blocks into an `IOBuffer(sizehint=…)` once; avoid repeated
  `string(...)` concatenation.
- Pre-size response buffers; write status line + headers + body into one buffer
  when the body is binary.

### 2.4 Parse lazily, memoize on first access

- Query string: keep the raw slice; parse on first `query`/`queryparams` access;
  cache in a mutable field. Requests that never touch the query pay nothing.
- Body: don't decode until asked. Cache the decoded form.
- Never parse at the transport boundary "just in case".

### 2.5 Measure before optimizing; then keep the measurement

- Every optimization lands with its before/after numbers in the WORKLOG and a
  guard test. Rejected optimizations get a one-line note too (so they aren't
  retried blindly).

---

## 3. Reliability patterns (bug-driven rules)

These are the exact classes of defect found in production-readiness campaigns.
Treat them as design constraints.

### 3.1 Know what a low-level "close" actually does

- A C library's `close_conn(ptr)` may **free the struct without closing the fd**
  (Mongoose's `mg_close_conn` did exactly that: fd leak + dangling epoll pointer →
  server wedge under a single slowloris).
- Rule: before using any low-level close/cancel, read its implementation. If it
  only *marks* (`is_closing`), use it and let the event loop reap. If it frees,
  never call it on a live handle.
- In Ciro's io_uring backend: every error path must complete/cancel SQE
  ownership exactly once; add an fd-count + ring-state leak test.

### 3.2 When you bypass the library's callback flow, re-implement its side effects

- Mongoose only set `is_draining` when a *synchronous* handler replied inside the
  callback; async replies (sent later) never triggered it, so `Connection: close`
  was echoed but the socket stayed open.
- Rule: any time work is deferred past the library's callback (thread pool,
  io_uring completion), audit which state the callback would have set and set it
  explicitly when the deferred step completes.

### 3.3 Phase-specific timeouts, cleared at the right event

- One timeout for "complete request" conflates headers and body: a slowloris
  guard then kills legitimate slow uploads.
- Use separate, opt-in limits: `header_timeout_ms` (incomplete headers) and
  `body_timeout_ms` (headers done, body pending). Clear the header timer at the
  **headers-complete** event, not at message-complete.
- Beware event semantics: Mongoose fired `MG_EV_HTTP_HDRS` on *every poll* while
  a body was pending — the handler must be idempotent per connection (use the
  body-tracking dict as the "already processed" marker).

### 3.4 Early rejection must not RST a client mid-upload

- Rejecting an oversized `Content-Length` at the headers event is good
  (bandwidth), but closing immediately resets clients still writing the body
  (HTTP.jl threw `ECONNRESET`).
- Correct pattern: send the error with `Connection: close`, remember the
  connection as "already answered", ignore the eventual complete-message event,
  and close only after the body finishes (or a body timeout fires).

### 3.5 Backpressure is mandatory for streaming

- A bounded producer channel alone is not enough: if the drain loop appends to an
  **unbounded** socket send buffer, one slow reader grows process memory without
  bound (measured: +25 MB while streaming 20 MB) and a drain burst stalls the
  event loop (~2 s).
- Pattern: bounded channel (producer blocks) **and** a cap on unsent bytes per
  connection (`stream_buffer_bytes`, default 1 MiB): the drain loop stops taking
  chunks when the connection's send buffer is at the cap.
- Verify with **live buffered bytes**, not process RSS — Julia's GC makes RSS
  noisy (heap churn). Expose a debug/metrics gauge for buffered bytes.

### 3.6 Never mutate shared/cached response objects

- `DEFAULT_404`-style shared error pages had `Connection: close`/`Retry-After`
  appended in place, so headers accumulated across requests (`"1,1,1,1"`).
- Pattern: copy-on-write header addition (`_add_header_once`), and make every
  helper return the new response — callers must assign the result.

### 3.7 Cap abandoned work; shed load explicitly

- Timeouts cannot kill Julia tasks. A timed-out handler keeps running; repeated
  timeouts accumulate runaway tasks beyond the worker pool and can exhaust the
  thread pool.
- Pattern: track runaways, cap them (`max_bg_tasks`, auto = 4×workers), and once
  the cap is reached shed **new** timed requests with `503` + `Retry-After: 1`;
  expose a gauge; document that the timeout bounds client latency, not handler CPU.

### 3.8 Metrics must count failures

- Handler exceptions bypassed the response path, so 500s were invisible in
  `http_requests_total` and the histogram.
- Pattern: record on the exception path too (`HTTPError` status if available,
  else 500), then rethrow so normal error mapping proceeds.

### 3.9 Know what the protocol layer already replies

- Mongoose auto-replies to WS PING (PONG) and CLOSE (echo + drain); the
  framework handler replying again duplicated every control frame.
- Rule: before adding a protocol-level reply, read the layer below; document who
  owns each control frame.

### 3.10 Host/address formatting

- `host="::1"` was passed unbracketed into the listen URL and bound nowhere.
  IPv6 literals must be `[::1]:port`. Test IPv6 and dual-stack (`::`) with a real
  client, and test the peer-address formatter (`::1` → stable expanded form).

### 3.11 Static files

- Decode percent-escapes **before** path checks (raw `..` and `%2e%2e` must both
  fail; null bytes rejected).
- Deny dotfiles by default (`.env`, `.git`), with `.well-known` excepted.
- Decide symlink policy and document it (POSIX follows symlinks; do not place
  links that escape the root).
- Keep a traversal matrix as a permanent test (raw, encoded, mixed, backslash,
  `....//`, absolute, null).

---

## 4. Testing & verification methodology

### 4.1 The gate set (run before every commit)

```sh
julia --project=test test/runtests.jl          # main suite
julia --project=test test/runtests_stream.jl   # same suite, threaded/streaming runner
julia --project=test test/acceptance/…         # wire-level acceptance (real server + real client)
julia --project=test test/quality/…            # Aqua + JET baseline
julia --project=docs docs/make.jl              # docs build (public API/docstrings)
```

- The **acceptance suite is the executable README**: one kitchen-sink server plus
  table-driven checks over the wire. It is the last gate before a release.
- Keep a second runner that exercises the same tests under a different execution
  mode (threads) — it catches races the default runner hides.

### 4.2 Adversarial campaigns (beyond the suite)

Build throwaway harnesses that talk to a real server with real clients. Minimum
matrix (all of these found real bugs in Mongoose):

| Area | Probes |
|---|---|
| Wire protocol | keep-alive reuse, pipelining, HTTP/1.0, HEAD, 405+Allow, chunked upload, `Expect: 100-continue`, malformed framing, oversized headers/body |
| Limits | slowloris (header timeout), slow body (body timeout), connection flood (max_connections), oversized `Content-Length` early 413 |
| Concurrency/soak | N×M parallel keep-alive, single-connection soak, abrupt RST disconnects, WS/SSE concurrency |
| Leaks | fd count, thread count, live buffered bytes, RSS trend (with GC caveats) |
| Lifecycle | repeated start/stop, bind conflict, drain with in-flight work, restart, registration-after-start |
| App layer | static traversal/dotfiles, WS fragmentation/limits/broadcast/origin, SSE slow consumer, multipart fuzzing, IPv6/dual-stack, per-IP ratelimit (XFF trust), sustained overload, metrics accuracy |
| TLS | real client (curl/HTTP.jl) with self-signed certs; later: protocol/cipher/client-cert matrix |

### 4.3 Every bug gets a wire-level regression test

- Unit tests are not enough for transport defects: `decode_chunked` was correct
  while **every chunked request over the wire hung**.
- Regression tests must exercise the same path that failed (raw socket or real
  client), and assert the *observable* contract (socket closed, header present,
  count exact), not internal bookkeeping.

### 4.4 Probe-writing pitfalls (cost us hours)

- `String(::Vector{UInt8})` **takes ownership and empties the vector** — copy
  first.
- `Channel` has no `length`; use `isready`/`isopen`.
- TCP reads coalesce/split: buffer per connection and slice responses exactly;
  don't assume one `recv` = one response.
- `pgrep -f pattern` matches the shell running the command — kill by PID file or
  match the interpreter name.
- Stale servers hold ports and serve old code: verify the boot banner/pid before
  probing; restart by PID.
- HTTP.jl retries/backs off on 429 and pools connections; pass `retry=false` for
  expected-error tests, and be deliberate about `Connection: close`.
- RSS is a poor leak signal in Julia (GC heap high-water); assert live
  structures/gauges instead.

---

## 5. API design & naming standards

- **Zero underscores on the public surface.** `isrunning`, `haspending`,
  `parsejson`, `getwsendpoint`, `haswsroutes`.
- Mutators end in `!` (`route!`, `ws!`, `freeze!`, `stop!`); predicates start
  `is*` / `has*` / `can*`; parsers are `parse*` verbs; accessors are nouns.
- Types: `TitleCase`, acronyms all-caps (`WSEndpoint`, `HTTPError`). Middleware
  builders are the lowercase name of their type (`cors()`, `metrics()`).
- Error types end in `*Error`; provide aliases for standard statuses
  (400–511) plus `statusreason(code)`; keep one deliberate gap documented
  (e.g. 501, because of `Base.NotImplementedError`).
- Implement Base protocols where they are obvious: `length`/`isempty`,
  `keys`/`values`/`pairs`, `==`, and terse one-line `show` for core types.
- During `0.x`, prefer breaking renames over deprecation shims; document every
  rename in the CHANGELOG. Never leave two names for the same concept.
- Keep a **router protocol** (not just the concrete `Trie`) so alternative
  routers are drop-in; ship a second implementation as a test of the seam.

---

## 6. Documentation & process standards

- **WORKLOG.md** is the canonical tracker: plan → task → commit hash → gates run.
  Add a HANDOFF block at the top for the next session.
- **CHANGELOG.md** (Keep a Changelog): `Fixed` / `Changed` / `Added` /
  `Known limitations`. Every user-visible behavior change gets a line; the
  "Known limitations" section stays honest and current.
- One commit per task; commit message states the *why* and the gates run.
- Keep a running **known-gotchas** list (include-order rules, naming traps,
  tooling traps). It saves more time than any style guide.
- Docstrings: Documenter cannot attach a docstring to a macro-invoked definition
  (`"""…""" @inline f(...) = …`); use a comment or attach at the type's end with
  `@doc """…""" Type`. Adding an export requires a manual `@docs` entry; a
  duplicate entry breaks the build.
- Keep the README's protocol/feature tables in sync with the code; the docs build
  is a gate for a reason.

---

## 7. Julia gotchas checklist

| Gotcha | Rule |
|---|---|
| `using .M` is read-only for method extension | facade must `import .M: f` for every generic the upper layers extend |
| Strict include order | structs used as field types must be defined before the composing struct; document the order |
| `String(::Vector{UInt8})` consumes the vector | `String(copy(v))` |
| `@async` is sticky | CPU-bound producers/loops need `Threads.@spawn`; never run producers on the poll thread |
| `Channel` has no `length` | `isready` / `isopen` |
| `sleep(Inf)` throws on 1.13 | loop `while true; sleep(3600); end` |
| Soft scope in scripts | wrap in functions or use `local`/`global` |
| `Base.length` shadowing (1.13) | write `Base.length(r::T)` explicitly |
| `timedwait(…; pollint=…)` | bounded waits for tasks; never fixed sleeps in tests |
| `eof`/`readuntil`/`readavailable` semantics | know which blocks; use tasks + `timedwait` to bound assertions |
| `@nospecialize` on stored callables | remove; it pessimizes types |
| Docstrings on macro invocations | use comments or `@doc` at the end of the type |

---

## 8. FFI / native backend discipline (io_uring)

- **Pin layout knowledge.** If you read a C struct field, record the offset, how
  it was verified (`offsetof` with the exact library version), and add a
  behavioral test. Do not trust arithmetic done from memory — a wrong offset
  silently corrupts neighboring fields.
- **Never call a free/close API from a different thread/task than the owner of
  the event loop.** Cross-task calls into a non-thread-safe C manager crashed in
  `mg_mgr_poll`; mark-only APIs called on the loop thread are safe.
- **Ownership rules for completions.** For every SQE: who allocates the buffer,
  who reads it, who frees it, and what happens on `-ECANCELED`/`-EAGAIN`/short
  reads. Write them down; test cancellation and RST paths.
- **Bound everything crossing the boundary**: header bytes, body bytes, frame
  bytes, connection count. The native layer's buffers are not a place for
  unbounded growth.
- Prefer the library's own reaping path (poll/loop) over immediate destruction.

---

## 9. Security checklist

- Limits (all opt-in with safe defaults, validated at construction):
  `max_body_size`, `max_header_bytes` (default 64 KiB), `header_timeout_ms`,
  `body_timeout_ms`, `max_connections`, `max_ws_frame`, `stream_buffer_bytes`.
- Static files: dotfile denial, decode-before-check, traversal matrix,
  documented symlink policy.
- Header injection: reject CRLF/control chars in every value the framework
  emits (cookies, redirect locations, echoed headers).
- Proxy headers: `X-Forwarded-For`/`X-Real-IP` are **ignored by default**
  (per-IP limits/logs key on the transport-provided peer address); trusting them
  is an explicit opt-in.
- Comparisons of secrets use constant-time equality.
- 405 carries `Allow`; 429/503 carry `Retry-After`; 413/431 are clean and do not
  reset clients mid-upload.
- Errors never leak stack traces or internal paths to clients by default.

---

## 10. Production-readiness checklist (before 1.0 / a release)

- [ ] All four gates green, plus the acceptance suite standalone.
- [ ] Adversarial campaign matrix run against the release commit (wire,
      concurrency/soak, lifecycle, leaks, app-layer, overload).
- [ ] CI runs: tests, quality (Aqua + JET baseline), docs, acceptance,
      coverage upload, TLS matrix, doctests.
- [ ] Version tagged; CHANGELOG complete; "Known limitations" accurate
      (e.g. AOT/`--trim` status, platform/Julia-version support).
- [ ] License compatible with dependencies (native backend + parser!).
- [ ] Benchmarks reproducible; allocation budgets asserted in CI.
- [ ] Deployment docs: systemd/Docker/reverse-proxy notes, TLS termination,
      graceful shutdown (SIGTERM drain), health/readiness endpoints.

---

## 11. Anti-patterns observed (do not)

1. **Calling a library's free/close on a live handle** because the name says
   "close". Read the implementation.
2. **Fixing a symptom in the tests** instead of the transport (e.g. forcing
   `Connection: close` everywhere to dodge keep-alive bugs).
3. **Mutating shared constants** (default responses, cached endpoints).
4. **Unbounded buffers anywhere** (send buffers, header reads, queues, tasks).
5. **One timeout for multiple phases** (headers vs body vs handler).
6. **Silent error paths** (metrics/logger that skip exceptions; close paths with
   no test).
7. **Second names for one concept** (`supports_websocket` + `has_ws_routes`).
8. **`@nospecialize`/`Any` in registration APIs** to "avoid recompilation".
9. **`@async` for CPU-bound work** on the event loop.
10. **Trusting docs/README claims without a wire test** — every claim in the
    README must have an executable check in the acceptance suite.

---

## 12. Ciro.jl — concrete application notes

Ciro already implements several of these patterns (`RouteResult` ADT,
`freeze!`, `FakeTransport`, parametric `Application{…}`, `TransportToken` with
generations, `AbstractBackend`/`AbstractExecutor`/`AbstractLogger`/`AbstractCatcher`).
The following are the highest-value checks to apply, in order:

1. **Backend close/cancel discipline (io_uring).** Audit every error path for
   exactly-once completion/cancellation and fd cleanup; add an fd-leak test with
   abrupt RST clients and a ring-state check. This is the class of bug that wedged
   Mongoose under a single slowloris.
2. **Limits and timeouts.** Add validated config for `max_header_bytes`,
   `header_timeout_ms`, `body_timeout_ms`, `max_connections`, and (if responses
   stream) `stream_buffer_bytes`. Ensure the parser cannot be fed unbounded
   header/body data.
3. **Streaming/backpressure.** If any response can outrun the socket, implement
   the bounded-channel + capped-unsent-bytes pattern and assert live buffered
   bytes in a test.
4. **Router polish.** Ensure `MethodMismatch` carries the allowed bitmask and the
   405 emits `Allow`; decide auto-HEAD explicitly; keep the compiled and generic
   dispatch results pinned equal by a parity matrix.
5. **Deferred-work correctness.** For anything answered off the event loop, audit
   which connection state the loop would have set (draining, close-after-flush,
   generation tokens) and set it when the deferred reply lands. Cap abandoned
   work and shed with 503 + `Retry-After`.
6. **Metrics/logger completeness.** Count failures (exceptions → status), and
   write each log line atomically under concurrency.
7. **Static file serving** (when added): dotfiles denied, decode-before-check,
   traversal matrix test, documented symlink policy.
8. **IPv6/dual-stack** bind + peer-address formatting, tested with a real client.
9. **Testing/CI.** Adopt the four gates; build an acceptance suite that doubles
   as the README; add the adversarial matrix above; keep Aqua + JET at zero.
10. **Process.** WORKLOG + CHANGELOG + one commit per task + a known-gotchas
    list; keep "Known limitations" honest.

> If a rule in this document conflicts with a measured improvement, update the
> document in the same PR — but bring numbers.
