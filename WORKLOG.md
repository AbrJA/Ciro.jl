# WORKLOG

Canonical tracker: plan → task → commit → gates run. Newest first.
See `docs/DESIGN_LESSONS.md` for the engineering standards and
`docs/DESIGN_REVIEW.md` for the audit, decisions and staged plan.

---

## RESUME — next session

State at pause:
- `feat/stage0-safety-net`: Stage 0 (`4b9d9a0`), Stage 1 (`b0a1996`), parser `0.3`
  alignment (`58afad7`), and Stage 2 (this commit) all done. `Pkg.test()` →
  **643 passed, 0 failed**; acceptance 36/36; PicoHTTPParser `0.3.0` resolves from
  General.
- Uncommitted: nothing (this section describes the committed state).

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

### Stage 3 — performance and type stability
- Zero-copy `Request`: views over `rbuf`, `copy` only when a handler lets them escape;
  lazy query/body parsing. Removes the ~3 KB/request materialization.
- Remove `Any` from routing (`RouteResult.handler`, `TrieNode.handlers`/`wildcard`);
  add `@inferred` + allocation-budget tests to CI.
- Optional: compiled dispatch table after `freeze!`, pinned equal to the generic path by
  a parity matrix.
- Idle memory: smaller/streamed read buffers; provided-buffer rings (kernel 5.19+/6.0).

### Backlog (order TBD)
- Wire tests for chunked transfer-encoding (decoder fixed, no HTTP-level coverage yet).
- Per-route body limits; `Expect: 100-continue`; early 413 without RST mid-upload.
- Access logging + metrics (count exceptions as 5xx too). `max_connections` currently
  sheds by closing silently; consider 503 + `Retry-After`.
- Async executor (v1.5): bounded queue, 503 shedding, request-copy semantics.
- SSE/streaming responses (v1.5 architecture) and static files (dotfile denial,
  traversal matrix).
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
