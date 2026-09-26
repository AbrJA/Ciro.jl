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
- `io_dispatch(io, request) -> Response` — run the application pipeline.

Optional capabilities (multishot accept, provided buffers, batching) are
reported through separate predicates, never required methods, so a plain
blocking-socket backend can satisfy the contract.
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
