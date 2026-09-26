# WORKLOG

Canonical tracker: plan → task → commit → gates run. Newest first.
See `docs/DESIGN_LESSONS.md` for the engineering standards and
`docs/DESIGN_REVIEW.md` for the audit, decisions and staged plan.

---

## RESUME — next session

State at pause:
- `dev`: Stages 0–2.5, async executor (`bacca8b`, `625c2bb`), streaming/SSE
  (`095058e`), zero-alloc route params (`a7690ab`), telemetry (`5b74dae`), and the
  lock-free-queue note (`0969dab`) committed; Stage 3.5 per-route limits
  uncommitted. `Pkg.test()` → **843 passed, 0 failed**; acceptance 118/118 (both
  backends); PicoHTTPParser `0.3.0` resolves from General.
- Uncommitted (this session): per-route limits — `RouteLimits` on `Endpoint`,
  early `io_route`, dispatch result reuse.

### Stage 3.5 — observability (uncommitted, this session)
- `Interface/telemetry.jl`: `AbstractTelemetry` with no-op defaults for
  `telemetry_request!`/`telemetry_response!`/`telemetry_read!`/
  `telemetry_exception!` and traits `telemetry_active`/`telemetry_capture_path`;
  built-in `ServerMetrics` (atomic counters + `metrics_snapshot`) and `AccessLog`
  (lock-serialized one-liner with target/status/bytes/elapsed).
- `Server` gained a telemetry type parameter (`Server{R,L,C,E,T}`) and a
  `telemetry=` keyword (default `NullTelemetry`).
- HTTP instrumentation: reads counted and per-request start time in
  `http_on_read`; request method/target/version reported after head parse
  (`_telemetry_begin`); every response reported once at `_queue_response`
  (protocol errors included; streams report at end or on abort in
  `http_finalize`); path copied only when `telemetry_capture_path` is true.
- Adapters expose `io_telemetry(io)` and dispatch through a per-call
  `_TelemetryCatcher` wrapper so intercepted exceptions are counted without
  changing `server.catcher` identity.
- Tests: `test/telemetry_test.jl` (20 unit) + 14 in-process sockets acceptance
  assertions (metrics counters incl. 400/404/500 + exceptions + bytes; AccessLog
  line for a real request). `Pkg.test()` 825; acceptance 111/111.

### Stage 3.5 — per-route limits (uncommitted, this session)
- `RouteLimits(; max_body_size=-1, body_timeout_ms=-1)` on `Endpoint` (new
  `limits` field); registration accepts `limits=` (all verbs + group proxy), and
  the auto-generated HEAD inherits it. `route_limits(handler)` accessor.
- Early routing: after the head is parsed, HTTP calls the optional
  `io_route(io, method, path, captures)` seam and stores the `RouteResult` on the
  connection; `_prepare_body`/`_feed_chunked!` use the route's body limit and
  `_set_deadline!` the route's body timeout. `dispatch`/`dispatch_async` gained a
  `result` argument so routing happens once; backends without `io_route` keep
  server-wide limits (default returns `nothing`).
- Tests: 11 router assertions (limits on Endpoint, HEAD inheritance, group proxy,
  validation) + 7 wire assertions (stricter/looser than the server limit, chunked
  413, per-route body timeout, sockets backend). `Pkg.test()` 843; acceptance
  118/118.

### Stage 3 — zero-allocation route params (committed: `a7690ab`)
- `RouteResult.params` values for Trie matches are now
  `Pair{Symbol,UnitRange{Int}}` byte ranges into the routed path; `param` resolves
  them to views on demand (`SubString(path(ctx.request), ...)`) and `copy(ctx)`
  materializes owned strings.
- `Interface.route!(router, method, path, captures)`: optional router method that
  fills a caller-provided scratch. `Trie` implements it; the default delegates to
  `route`, so custom routers are unaffected. `Runtime.dispatch`/`dispatch_async`
  gained a scratch argument; `HTTPConn` owns the reused scratch and the adapters
  pass it through the 3-arg `io_dispatch`.
- Public `route` still returns owned strings (self-contained results); only the
  served path uses ranges. Bench: `route! static/param = 0 B`, public `route`
  unchanged (32/144 B).
- `@inferred` guards for `route`, `route!`, `dispatch`, and `param`; scratch tests
  cover aliasing, resolution, `copy(ctx)`, and `isempty` for static routes.
  `Pkg.test()` 789; acceptance 97/97.

### v1.5 — Async executor (committed: `bacca8b`, `625c2bb`)
- `AsyncExecutor(worker_threads=2, max_pending=256)`: unbounded job `Channel` gated
  by an atomic `pending` counter, `503` + `Retry-After: 1` on overload, `shed_count`/
  `pending_count` for metrics/tests. `stop_executor!` does not join hung workers
  (a hung handler must not wedge shutdown).
- `Runtime.dispatch_async(router, executor, catcher, request, reply)::Bool`: one
  routing path for both executors; sync replies inline (`false`), async copies the
  request (copy-on-escape), submits, replies later (`true`); `reply` is called
  exactly once either way.
- HTTP seam: optional `io_isasync`/`io_dispatch_async` (default methods preserve the
  sync contract for third-party adapters), new `:awaiting` phase (no read armed, no
  deadline), and `http_deliver_response` as the single delivery entry point
  (`http_finalize` now sets `retired` so a released state can't be mutated again).
- Adapters: UringIO delivers via a generation-checked reply inbox drained in
  `on_tick`; SocketsIO uses one reply channel per connection, consumed by the
  connection task (`_sockets_close` closes it to wake a waiter). Shutdown lets
  `:awaiting` connections finish, then forces at `shutdown_timeout`.
- Server: `start_executor!`/`stop_executor!` around the worker loops; warns when
  `nthreads() <= nworkers` because handlers then share event-loop threads.
- Event-loop fix: `run_eventloop!` submits after `on_tick`; without it, writes queued
  by reply delivery were never flushed when no completion arrived.

### v1.5 — Streaming/SSE (committed: `095058e`)
- `Interface/stream.jl`: `Stream` + `stream(body)` / `sse(body)` builders, a
  `StreamWriter <: IO` (print/println/write; `close` ends the response) and an
  `SSESender` (id/event/retry/data framing). Sync executors reject `Stream` with
  a 500 (a sync body would block the event loop).
- HTTP: `:streaming` phase; `serialize_head!` (TE: chunked unless the user
  supplied `Content-Length`, raw for HEAD/HTTP1.0), `serialize_chunk!`,
  `serialize_last_chunk!`; one flush in flight, acked per chunk for backpressure;
  `_finish_stream` resumes keep-alive/pipelining; `http_finalize` fails the
  handshake so a disconnected client releases its worker.
- Core: `_Outbound` messages (`_Reply`/`_StreamBegin`/`_StreamChunk`/`_StreamEnd`)
  marshalled from workers; `_run_stream` runs the body and blocks on acks. UringIO
  drains the inbox in `on_tick` (generation-checked); SocketsIO consumes the
  per-connection channel in the connection task. Shutdown lets streams finish
  until `shutdown_timeout`.
- Tests: `test/stream_test.jl` (30: builders, SSE framing, worker protocol,
  disconnect, framing helpers) + 23 wire assertions on both backends (chunked,
  SSE, Content-Length raw, pipelining after stream, sync 500, disconnect with
  `max_pending=1`). `Pkg.test()` 775; acceptance 97/97.

### Next
- Compiled routing (dispatch table at `freeze!`); `Expect: 100-continue`; Stage 4
  packaging (untrack `lib/ciro.so`, JLL, docs build, CI matrix); static files.

### Stage 2 — DONE (one pipeline, graceful shutdown)
- Single dispatch pipeline: `Runtime.dispatch(router, executor, catcher, request)` is
  the only path; `Core._dispatch` and `Application` delegate to it; a parity test pins
  Application and Server results equal. `_invoke_handler` duplication removed.
- One `stop!` generic owned by `Interface` (`stop!(server)` and `stop!(app)` both
  work); FakeTransport's `submit!` renamed `enqueue!` (no clash with `Backend.submit!`).
- Graceful drain: `run_eventloop!` takes a `drain` predicate; workers flush in-flight
  writes, close idle/partial connections, and force-close after `shutdown_timeout`.
  `run_eventloop_threaded!` stops peers and waits for drain on failure/interrupt.
- `yield()` in the event loop fixed the in-process scheduler deadlock (P0 #12) and
  makes Ctrl-C/SIGINT deliverable; the drain is covered by an in-process acceptance test.
- SIGTERM is swallowed by Julia 1.13's runtime (verified: neither `signal()` nor a C
  `sigaction` handler runs), so the documented stop signals are SIGINT
  (`docker stop --signal=SIGINT`, systemd `KillSignal=SIGINT`) and `stop!`.

### Stage 2.5 — DONE (HTTP seam, portable backend, config split)

- Chunked wire coverage (complete, fragmented, trailers, pipelined, 413) exposed and fixed
  a real bug: leftover after a chunked message was installed into `rbuf` before the head
  was materialized (`a690fec`).
- New `HTTP` module: `AbstractIO` byte-transport seam and response serialization
  (`015fb7d`); the connection state machine followed into `HTTP/state.jl`, leaving
  `Core/worker.jl` a 288-line adapter + event pump (`2c22a7c`).
- `ServerConfig` split from `ServerRuntime` (`0852817`).
- Sockets backend (`218f3eb`): `Server(; backend=:sockets)` implements the full seam with
  blocking sockets and per-connection tasks; acceptance runs the whole wire suite against
  it. This is the proof the seam is transport-agnostic.
- E2 done early: per-connection pending writes replace the fd-indexed table; fd-reuse
  hazards are gone.
- Gates at each commit: acceptance 51/51; `Pkg.test()` -> 658 passed, 0 failed.

### Stage 3 — PARTIAL (3a/3b done; routing/params pending)
- [x] Zero-copy request views: method/target/path/query/headers/body as views, lazy
  `Headers`, copy-free routing. Request construction measured 4088 B -> 480 B, guarded
  by an allocation-budget test.
- [x] `copy(req)`/`copy(ctx)` escape hatch, documented (retention rule) and tested.
- [ ] Routing `Any`/params: parametric `RouteResult{H}` alone does not remove the trie's
  dynamic dispatch; the real win is a reusable params scratch threaded through
  `Runtime.dispatch` (or a compiled dispatch table at `freeze!` with a parity matrix).
- [ ] `@inferred` guards and tighter budgets in CI; idle memory (smaller/streamed read
  buffers, provided-buffer rings).

### Backlog (order TBD)
- Wire tests for chunked transfer-encoding (decoder fixed, no HTTP-level coverage yet).
- Per-route body limits; `Expect: 100-continue`; early 413 without RST mid-upload.
- Access logging + metrics (count exceptions as 5xx too). `max_connections` currently
  sheds by closing silently; consider 503 + `Retry-After` (the async executor already
  uses 503 shedding).
- Static files (dotfile denial, traversal matrix), per-route streaming limits
  (chunk size / max stream duration), SSE keepalive comments.
- Perf (evidence-gated, do not do speculatively): if a profile shows `Channel` lock
  contention, evaluate replacing only the UringIO reply inbox with a lock-free queue
  (ConcurrentCollections.jl `ConcurrentQueue`, or a bounded ring sized from
  `max_pending`/`queue_depth`). Keep `Channel` for stream acks and
  `SocketsEntry.reply`: blocking `take!` plus `close`-to-wake is load-bearing
  (disconnect/shutdown must release workers), and `close(jobs)` is the executor
  shutdown wakeup. ConcurrentCollections has no close/failure semantics.
- Packaging: JLL artifact, untrack `lib/ciro.so`, docs build, Linux-only CI matrix.

### Gotchas from this session (don't relearn)
- `close()` on a socket with a pending io_uring read does not FIN the peer: the request
  holds the file description. Call `shutdown()` first, close after the completion.
- Preallocated `Base.RefValue` fields passed to `ccall` allocate 16 B each. Keep refs as
  locals (elided) or use pointer-out parameters.
- `bytesavailable` on Julia sockets is not a readiness check without an in-flight read.
- The event loop never yields, so an in-process Julia client can deadlock the scheduler;
  wire tests use a server subprocess plus raw libc sockets.
- Header views must be offset-based: growing `rbuf` reallocates and dangles absolute
  pointers.
- fd-indexed state (`PendingWrites.close_after`) must be reset whenever an fd is reused.
- `make -C lib` check-deps needed `_GNU_SOURCE` for `SO_REUSEPORT` with modern glibc.
- `Threads.@spawn` tasks are pinned to the world age at spawn. Long-lived workers
  (and anything else that outlives `start!`) must run user code with
  `Base.invokelatest`, or closures/methods defined later fail with a MethodError
  that can be swallowed by the worker's error path.
- Queuing I/O from `on_tick` requires a `submit!` after the tick; otherwise SQEs sit
  unsubmitted until the next unrelated completion.
- Streaming serializes chunk flushes through a single `stream_ack` slot: never
  process a second chunk event for the same connection before the first ack.
- A zero-length chunk is the HTTP terminator — `http_stream_chunk` acks empty
  writes without serializing them.
- `_complete_request` must dispatch **before** advancing `rbuf`; advancing first
  corrupts the request views (symptom: pipelined/keep-alive requests route as 404).
- `println(io, x)` issues two writes (data, then newline), so a chunk per write
  means a chunk per argument.
- Served route params alias the connection scratch and ranges resolve against
  `ctx.request.path`: build manual contexts from the same path that was routed
  (public `route` returns owned strings precisely so its result is self-contained).
- `@allocated` at the REPL top level can report a phantom 32 B box for any
  non-isbits struct returned by a dynamic call. Measure inside a compiled function
  (single-call wrapper) before concluding there is a real allocation.
- PicoHTTPParser accessors do not always match Ciro's stored types (e.g.
  `minor_version` returns `Int`, while `Request.minor_version` is `UInt8`);
  convert at the boundary. A `MethodError` showing an extra hidden argument is a
  world-age display, but here it was just a type mismatch.
- New optional `io_*` seam methods must be added to Core's `import ..HTTP: ...`
  list, or `io_foo(io::UringIO) = ...` silently defines a *new* `Core.io_foo`
  that HTTP never calls (this bit twice: `io_telemetry`, `io_route`).

### Resume commands
```sh
cd ~/Documents/GitHub/Julia/Packages/Ciro.jl
git log --oneline -5
git status
cd lib && make && cd ..        # only if the C sources changed
JULIA_NUM_THREADS=4 julia --project=. -e 'using Pkg; Pkg.test()'
```

---

## HANDOFF — Stage 1: correctness core (2026-09-24)

Branch: `feat/stage0-safety-net` (continues; Stage 1 changes not committed yet).

### Done

- Incremental per-connection state machine in `src/Core/worker.jl`:
  - `rbuf` accumulation, `parse_request_head!` with `last_len`, left-over carry and
    pipelining;
  - retired-connection protocol: a struct is only recycled after every in-flight
    io_uring operation completes, so stale completions cannot hit a reused struct;
  - one op in flight per connection (`:read`/`:write`/`:none`).
- Validated config/limits on `Server`: `max_header_bytes`, `header_timeout_ms`,
  `body_timeout_ms`, `idle_timeout_ms`, `max_connections` (plus `max_body_size`),
  enforced by a per-worker on-tick deadline sweep (431/413 answers; timeouts close).
- `host` and `backlog` are wired to the native bind; `Server` now actually goes through
  `IOUringBackend`/`AbstractBackend` (the seam is no longer decorative).
- SQE exhaustion is no longer silent: C queue helpers return status and every Julia
  failure path retires the connection instead of dropping the operation.
- HEAD responses carry the GET entity's `Content-Length`; `Response` rejects CR/LF/NUL
  in header names/values at construction.
- Ownership bugs found and fixed by the new tests:
  - fd-indexed `close_after` leaked across fd reuse (`set_pending!` now clears it);
  - `close()` on a socket with a pending io_uring read does not FIN the peer — the
    request holds the file description alive. `shutdown()` now wakes the read and FINs,
    and the fd is closed after the completion (`shutdown_fd!`).
- Parser (`PicoHTTPParser.jl`): offset-based header views survive buffer growth
  (commit `ccd41c6`); allocation-free `parse_request_head!` (commit `07215a5`).

### Gates

- `Pkg.test()` → **614 passed, 0 failed** (full Aqua + JET + 29 wire tests).
- All six Stage 0 `@test_broken` pins promoted to `@test`; added wire coverage for 431,
  413, header timeout, body timeout and idle timeout.

### Blocked / next

- CI: `PicoHTTPParser 0.3.0` is released and awaiting General registration
  (JuliaRegistries/General#169521). Local runs use the gitignored Manifest dev path;
  once the PR merges, resolving from the registry unblocks CI.
- Next: chunked transfer-encoding wire tests; per-route body limits; access logging;
  async executor (v1.5); zero-copy `Request` (Stage 3); JLL packaging (Stage 4).

---

## HANDOFF — Stage 0: safety net (2026-09-24)

Branch: `feat/stage0-safety-net` (changes not committed yet).

### Done

- [x] Lazy native-library loading. `using Ciro` no longer requires `lib/ciro.so`:
      `Backend._LIB_AVAILABLE` is set in `__init__`, `buffer_size()` queries the native
      constant on first use, and `start_backend!` fails fast with a clear message.
- [x] Wire acceptance suite (`test/acceptance_test.jl`):
      - server runs in a subprocess (mirrors deployment; avoids the non-yielding event
        loop deadlocking an in-process client — see finding below);
      - client uses raw blocking libc sockets (no libuv);
      - 14 assertions pass; 6 P0 defects pinned with `@test_broken`:
        split headers, split body, body larger than the read buffer, pipelining,
        HEAD entity length, CRLF header injection.
- [x] CI (`.github/workflows/CI.yml`): Linux-only job, installs `liburing-dev` and
      builds `lib/ciro.so` before tests; docs job disabled with an explicit note
      (returns in Stage 4); coverage kept.
- [x] Quality gates restored: full `Aqua.test_all(Ciro)` (ambiguities, piracies,
      compat bounds) and JET targeting all submodules.
- [x] `Project.toml`: `Dates = "1.11.0"` removed (it blocked the declared Julia 1.10
      floor); stdlib compat entries added (`Dates`, `Sockets`, `Test`); `Sockets` added
      to the test target.

### Gates run

- `JULIA_NUM_THREADS=4 julia --project=. -e 'using Pkg; Pkg.test()'`
  → **599 pass, 6 broken, 0 fail** (Julia 1.13.0, Linux, liburing present).
- `using Ciro` in a fresh copy without `lib/ciro.so` → loads (warns), backend errors
  only at `start!`.

### Findings from this stage

- **In-process deadlock (P0, tracked for Stage 1).** `run_eventloop!` never yields while
  spinning on `wait_completion` ccalls. A worker task can occupy a thread the Julia
  scheduler needs, so an in-process Julia client deadlocks mid-`write` and unrelated
  libuv calls (`listen`) can stall. Python clients and subprocess servers are unaffected.
  Real fix: yielding/event-loop scheduling in Stage 1/2.
- **`bytesavailable` is not a readiness check.** Julia only buffers socket data while a
  read is in flight; polling `bytesavailable` returns 0 forever. Acceptance helpers use
  blocking reads with timeouts instead.

### Parser API ready (other repo)

`PicoHTTPParser.jl` branch `feat/incremental-head-api`: allocation-free
`parse_request_head!` (stateful `HeaderBuffer`, `:partial`/`:done`/`:error`), lazy header
accessors, and a corrected in-place `decode_chunked!` with `:partial`/`:done`/`:error`
plus `leftover` for pipelining. 82/82 tests pass; version 0.3.0 (breaking). Stage 1
should `Pkg.develop` this path into Ciro while the API settles.

### Next — Stage 1: correctness core

1. Per-connection read buffer with incremental parsing (`last_len`), leftover carry,
   pipelining; `400` only on genuine parse errors.
2. `ServerConfig` validated at construction: `max_header_bytes`, `header_timeout_ms`,
   `body_timeout_ms`, `idle_timeout_ms`, `max_connections`, `max_body_size`.
3. SQE exhaustion returns status from C; no silent drops.
4. Fix HEAD, CRLF/header validation, `host`/`backlog` wiring or removal.
5. Flip each `@test_broken` in `test/acceptance_test.jl` to `@test`.
