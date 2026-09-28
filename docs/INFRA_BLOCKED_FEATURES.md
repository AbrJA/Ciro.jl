# Infrastructure-Blocked Features

These features **cannot be cleanly implemented** without changes to the Backend (C library / io_uring layer). They require low-level control over socket I/O that the current Julia-side code does not have access to.

---

## 1. Chunked Transfer Encoding (HTTP/1.1)

**Why blocked:** Chunked responses require writing multiple frames to the socket incrementally (each chunk prefixed with its hex length). The current Backend exposes a single `queue_write!(engine, conn, ptr, len)` call per response — there is no mechanism for multi-part streaming writes.

**What would be needed:**
- A `queue_writev!` (scatter/gather I/O) or a coroutine-based write loop in the C layer
- `io_uring` supports `IORING_OP_WRITEV` natively, so this is feasible but requires C changes

**Alternative (no Backend change):** Pre-assemble the entire chunked body in a buffer before calling `queue_write!`. This works for small/medium responses but defeats the purpose for large streaming responses.

---

## 2. 100-Continue Handling

**Why blocked:** The server must send an interim `HTTP/1.1 100 Continue\r\n\r\n` response *before* reading the request body, then continue reading. The current event loop reads the full request in a single `READ` completion — there is no state machine for partial request processing.

**What would be needed:**
- A two-phase read state machine in the C layer: parse headers → check Expect → send 100 → read body
- Or: expose a `queue_write_then_read!` compound operation

**Alternative:** Ignore the `Expect: 100-continue` header entirely (many servers do this). Clients are required by RFC 9110 §10.1.1 to send the body after a timeout anyway.

---

## 3. Request Timeouts / Slow Loris Protection

**Why blocked:** The Backend's event loop processes completions as they arrive from `io_uring`. There is no per-connection timer that can fire independently to close idle connections.

**What would be needed:**
- `IORING_OP_TIMEOUT` linked to each read operation (io_uring supports this via linked SQEs)
- Or: a separate timer wheel in the C layer that closes stale fds

**Alternative:** Use `SO_RCVTIMEO` / `SO_SNDTIMEO` socket options (set at accept time). This gives coarse-grained protection without C changes but doesn't integrate with io_uring's timeout system.

---

## 4. Keep-Alive Idle Timeout

**Why blocked:** After responding, the server queues another `READ` and waits indefinitely. Without a timeout, connections that go silent are never reaped.

**What would be needed:**
- Same timer infrastructure as #3 (linked `IORING_OP_TIMEOUT`)
- A `max_idle` setting passed down to the C layer

**Alternative:** Accept the leak risk for now. Under high load, file descriptor limits will eventually force the OS to refuse new connections. A userspace reaper thread (periodically walking a connection table) could work but adds complexity and cross-thread communication.

---

## 5. Streaming / Server-Sent Events (SSE)

**Why blocked:** SSE requires holding a connection open and writing event frames over time. The Backend assumes one write per request then done (optionally close or re-read).

**What would be needed:**
- A "long-lived connection" mode where the Julia side can queue multiple writes over time
- Probably a channel-based interface: `send_event!(conn, data)` that enqueues writes to io_uring

**Alternative:** WebSocket support has the same fundamental requirement. Both are Phase 3 features that warrant a streaming Backend extension.

---

## Recommended Path Forward

1. **Short-term:** Implement the `SO_RCVTIMEO` alternative for basic timeout protection (no C changes).
2. **Medium-term:** Add `IORING_OP_WRITEV` support to the C library for chunked encoding.
3. **Long-term:** Design a streaming connection abstraction for SSE/WebSocket (Phase 3).

All of these are *additive* — they don't require breaking the existing Backend API. The current design handles the 90% case (request → response → done) extremely well.
