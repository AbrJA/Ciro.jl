"""
    Backend

Low-level async I/O engine built on Linux io_uring.
Provides completion-based primitives (accept, read, write) that higher-level
packages (HTTP servers, WebSockets, databases) can build upon.

Design principles:
- Zero-allocation hot paths (pooled connections & buffers)
- trim=safe: no eval, no reflection, all concrete types
- Thread-per-core: one Engine per thread, no cross-thread sharing
- Composable: event loop is a simple function users can wrap/extend
"""
module Backend

# ── Library path (module-level const required by ccall + juliac) ─────────────
# In production this becomes Ciro_jll.libciro
const _LIB = normpath(joinpath(@__DIR__, "..", "..", "lib", "ciro.so"))

# ── Includes ────────────────────────────────────────────────────────────────
include("types.jl")
include("connection.jl")
include("engine.jl")
include("pool.jl")
include("eventloop.jl")

# ── Public API ──────────────────────────────────────────────────────────────
export Engine, Connection, ConnectionPool, BufferPool,
       EventType, ACCEPT, READ, WRITE,
       CompletionEvent,
       # Engine lifecycle
       init_engine, close_engine!,
       # Operations
       queue_accept!, queue_multishot_accept!, queue_read!, queue_write!,
       submit!, wait_completion, poll_completion,
       # Fast-path combined operations
       accept_and_queue_read!, queue_write_and_close!, queue_read_reuse!,
       # Connection management
       create_connection, free_connection!,
       configure_socket!, close_fd!, conn_fd, conn_buffer, set_conn_fd!, set_conn_op!,
       # Pools
       acquire!, release!,
       PendingWrites, set_pending!, pop_pending!, mark_close!, should_close!,
       # Event loop
       run_eventloop!, run_eventloop_threaded!

end # module Backend
