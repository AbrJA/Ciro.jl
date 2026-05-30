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

import ..Interfaces: AbstractBackend, start_backend!, stop_backend!

# ── Library path (module-level const required by ccall + juliac) ─────────────
# In production this becomes Ciro_jll.libciro
const _LIB = normpath(joinpath(@__DIR__, "..", "..", "lib", "ciro.so"))

function __init__()
    if !isfile(_LIB)
        @warn """Ciro: native library not found at $_LIB
        The io_uring backend requires compiling the C library:
          cd lib && make
        Without it, `start!()` will fail."""
    end
end

# ── Includes ────────────────────────────────────────────────────────────────
include("types.jl")
include("connection.jl")
include("engine.jl")
include("pool.jl")
include("eventloop.jl")

# ── IOUringBackend — concrete AbstractBackend ───────────────────────────────

"""
    IOUringBackend <: AbstractBackend

Linux io_uring backend (kernel ≥ 5.19). Thread-per-core with SO_REUSEPORT.
This is the default backend used by `Server`.
"""
struct IOUringBackend <: AbstractBackend
    queue_depth :: Int
    nworkers    :: Int
end

IOUringBackend(; queue_depth::Int=4096, nworkers::Int=Threads.nthreads()) =
    IOUringBackend(queue_depth, nworkers)

function start_backend!(backend::IOUringBackend, handler_factory::F, port::Integer;
                                   running::Threads.Atomic{Bool}=Threads.Atomic{Bool}(true)) where {F}
    isfile(_LIB) || error("Ciro: native library not found at $_LIB. Compile with: cd lib && make")
    run_eventloop_threaded!(handler_factory, port;
                            nthreads=backend.nworkers,
                            queue_depth=backend.queue_depth,
                            running)
end

function stop_backend!(::IOUringBackend)
    nothing  # Stopping is handled via the `running` atomic flag
end

# ── Public API ──────────────────────────────────────────────────────────────
export IOUringBackend,
       Engine, Connection, ConnectionPool, BufferPool,
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
