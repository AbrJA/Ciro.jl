# ══════════════════════════════════════════════════════════════════════════════
# AbstractIO — the byte-transport seam
#
# The HTTP layer consumes this contract; a backend adapter implements it
# (io_uring today; blocking sockets + Timer later). The HTTP layer never sees
# fds, rings, or pools.
#
# Return-code convention: 0 is success, non-zero is fatal for the connection
# (the caller retires it). No operation may be silently dropped.
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractIO

Byte-transport contract consumed by the HTTP layer and implemented by a
backend adapter. All operations are keyed by the opaque per-connection state
`st` owned by the HTTP layer.

Required methods:

- `io_config(io) -> HTTPConfig` — limits and deadlines.
- `io_running(io) -> Bool` — false once shutdown started (stop accepting and
  drain).
- `io_read(io, st) -> Int` — arm one read into the connection's buffer.
- `io_acquire_buffer(io) -> Vector{UInt8}` — pooled response buffer.
- `io_write(io, st, buf, len) -> Int` — queue a response; the adapter owns
  `buf` until the write completes and returns it to its pool.
- `io_on_write(io, st, nbytes) -> Symbol` — advance a write completion:
  `:partial` (remainder resubmitted), `:done`, or `:error`.
- `io_shutdown(io, st)` — wake a pending operation and FIN the peer.
- `io_close(io, st)` — release the socket and any queued buffer.
- `io_release(io, st)` — detach the connection state and recycle it.
- `io_dispatch(io, request) -> Response` — run the application pipeline. A
  backend may instead implement `io_dispatch(io, request, captures)`, receiving
  the connection's reusable route-capture scratch so routing does not allocate
  (the default 3-argument method forwards to the 2-argument one).
- `io_telemetry(io) -> AbstractTelemetry` — per-request observer (metrics,
  access log); defaults to `NullTelemetry()`.

Optional capabilities (multishot accept, provided buffers, batching) are
reported through separate predicates, never required methods, so a plain
blocking-socket backend can satisfy the contract.

Asynchronous dispatch is opt-in through two defaulted methods:

- `io_isasync(io) -> Bool` — whether `io_dispatch_async` may return before the
  response exists (default `false`).
- `io_dispatch_async(io, st, request) -> Bool` — dispatch and arrange delivery
  through [`http_deliver_response`](@ref). Returns `true` when delivery is
  deferred. The default runs `io_dispatch` inline and delivers immediately.
  A backend that returns `true` must call `http_deliver_response` on its
  event-loop thread; the connection sits in the `:awaiting` phase until then.
"""
abstract type AbstractIO end

function io_config end
function io_running end
function io_read end
function io_acquire_buffer end
function io_write end
function io_on_write end
function io_shutdown end
function io_close end
function io_release end
function io_dispatch end
function io_isasync end
function io_dispatch_async end
function io_telemetry end

"Backends without deferred dispatch are synchronous."
io_isasync(::AbstractIO)::Bool = false

"Backends that do not use the connection's route-capture scratch."
io_dispatch(io::AbstractIO, req::Request, captures) = io_dispatch(io, req)

"Backends without an observer are unobserved."
io_telemetry(::AbstractIO) = NullTelemetry()
