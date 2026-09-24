# WORKLOG

Canonical tracker: plan → task → commit → gates run. Newest first.
See `docs/DESIGN_LESSONS.md` for the engineering standards and
`docs/DESIGN_REVIEW.md` for the audit, decisions and staged plan.

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

### Next — Stage 1: correctness core

1. Per-connection read buffer with incremental parsing (`last_len`), leftover carry,
   pipelining; `400` only on genuine parse errors.
2. `ServerConfig` validated at construction: `max_header_bytes`, `header_timeout_ms`,
   `body_timeout_ms`, `idle_timeout_ms`, `max_connections`, `max_body_size`.
3. SQE exhaustion returns status from C; no silent drops.
4. Fix HEAD, CRLF/header validation, `host`/`backlog` wiring or removal.
5. Flip each `@test_broken` in `test/acceptance_test.jl` to `@test`.
