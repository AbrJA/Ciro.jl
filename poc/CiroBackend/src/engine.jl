# ══════════════════════════════════════════════════════════════════════════════
# Engine — io_uring instance lifecycle and I/O operations
# ══════════════════════════════════════════════════════════════════════════════

"""
    init_engine(port; queue_depth=4096) -> Engine

Initialize an io_uring engine bound to `port`.
Creates the server socket with SO_REUSEADDR + SO_REUSEPORT (enables
thread-per-core scaling where each thread binds the same port).

Returns `nothing` if initialization fails.
"""
function init_engine(port::Integer; queue_depth::Integer=4096)::Union{Engine, Nothing}
    ptr = ccall((:init_engine, _LIB), Ptr{Cvoid}, (Cint, Cint), Cint(port), Cint(queue_depth))
    ptr == C_NULL && return nothing
    return Engine(ptr, port)
end

"""
    close_engine!(engine::Engine)

Tear down the io_uring ring and close the server socket.
"""
function close_engine!(engine::Engine)
    engine.ptr == C_NULL && return nothing
    ccall((:cleanup_engine, _LIB), Cvoid, (Ptr{Cvoid},), engine.ptr)
    engine.ptr = C_NULL
    nothing
end

# ── Queue Operations ────────────────────────────────────────────────────────
# These add SQEs to the submission queue. Call submit!() to flush.

"""Queue a single-shot accept on the server socket."""
@inline function queue_accept!(engine::Engine, conn::Connection)
    ccall((:queue_accept, _LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine.ptr, conn.ptr)
    nothing
end

"""Queue a multishot accept (kernel 5.19+). One SQE serves multiple accepts."""
@inline function queue_multishot_accept!(engine::Engine, conn::Connection)
    ccall((:queue_multishot_accept, _LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine.ptr, conn.ptr)
    nothing
end

"""Queue a read into the connection's internal buffer."""
@inline function queue_read!(engine::Engine, conn::Connection)
    ccall((:queue_read, _LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine.ptr, conn.ptr)
    nothing
end

"""
    queue_write!(engine, conn, data::Ptr{UInt8}, len)

Queue a write from `data` (len bytes). The caller MUST keep the data alive
(via GC.@preserve or pool ownership) until write completion.
"""
@inline function queue_write!(engine::Engine, conn::Connection, data::Ptr{UInt8}, len::Integer)
    ccall((:queue_write, _LIB), Cvoid,
        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Cint),
        engine.ptr, conn.ptr, data, Cint(len))
    nothing
end

# ── Submission & Completion ─────────────────────────────────────────────────

"""Submit all pending SQEs to the kernel. Returns number submitted."""
@inline function submit!(engine::Engine)::Cint
    ccall((:submit_pending, _LIB), Cint, (Ptr{Cvoid},), engine.ptr)
end

"""
    wait_completion(engine; timeout_ms=10) -> Union{CompletionEvent, Nothing}

Block until a completion arrives or timeout expires.
Returns `nothing` on timeout (no event ready).
"""
@inline function wait_completion(engine::Engine; timeout_ms::Integer=10)::Union{CompletionEvent, Nothing}
    res = Ref{Cint}(0)
    conn_ptr = ccall((:wait_completion, _LIB), Ptr{Cvoid},
        (Ptr{Cvoid}, Ref{Cint}, Cint), engine.ptr, res, Cint(timeout_ms))
    conn_ptr == C_NULL && return nothing
    op = ccall((:get_conn_op_type, _LIB), Cint, (Ptr{Cvoid},), conn_ptr)
    return CompletionEvent(conn_ptr, res[], EventType(op))
end

"""
    poll_completion(engine) -> Union{CompletionEvent, Nothing}

Non-blocking peek at the next completion. Returns `nothing` if none ready.
"""
@inline function poll_completion(engine::Engine)::Union{CompletionEvent, Nothing}
    res = Ref{Cint}(0)
    conn_ptr = ccall((:poll_completion, _LIB), Ptr{Cvoid},
        (Ptr{Cvoid}, Ref{Cint}), engine.ptr, res)
    conn_ptr == C_NULL && return nothing
    op = ccall((:get_conn_op_type, _LIB), Cint, (Ptr{Cvoid},), conn_ptr)
    return CompletionEvent(conn_ptr, res[], EventType(op))
end

"""
    accept_and_queue_read!(engine, conn, client_fd)

Combined: set fd on conn + queue read. One ccall instead of 3.
"""
@inline function accept_and_queue_read!(engine::Engine, conn::Connection, client_fd::Cint)
    ccall((:accept_and_queue_read, _LIB), Cvoid,
        (Ptr{Cvoid}, Ptr{Cvoid}, Cint), engine.ptr, conn.ptr, client_fd)
    nothing
end

"""
    queue_write_and_close!(engine, conn, data, len)

Combined: queue write + linked close. Kernel handles write→close atomically.
"""
@inline function queue_write_and_close!(engine::Engine, conn::Connection, data::Ptr{UInt8}, len::Integer)
    ccall((:queue_write_and_close, _LIB), Cvoid,
        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Cint), engine.ptr, conn.ptr, data, Cint(len))
    nothing
end

"""
    queue_read_reuse!(engine, conn)

Queue read reusing same conn (keep-alive). One ccall.
"""
@inline function queue_read_reuse!(engine::Engine, conn::Connection)
    ccall((:queue_read_reuse, _LIB), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine.ptr, conn.ptr)
    nothing
end
