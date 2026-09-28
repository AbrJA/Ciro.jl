# ══════════════════════════════════════════════════════════════════════════════
# Connection — thin wrapper over conn_t* with ccall accessors
# ══════════════════════════════════════════════════════════════════════════════

const _BUFFER_SIZE = Ref{Int}(0)

"""
    buffer_size() -> Int

Native connection read-buffer size. Queried lazily on first use so that loading
the package does not require the native library to be present.
"""
function buffer_size()::Int
    if _BUFFER_SIZE[] == 0
        _LIB_AVAILABLE[] ||
            error("Ciro: native library not found at $_LIB. Compile with: cd lib && make")
        _BUFFER_SIZE[] = Int(ccall((:get_conn_buffer_size, _LIB), Cint, ()))
    end
    return _BUFFER_SIZE[]
end

"""Create a new connection (heap-allocated conn_t)."""
@inline function create_connection()::Connection
    ptr = ccall((:create_connection, _LIB), Ptr{Cvoid}, ())
    return Connection(ptr)
end

"""Free a connection (returns conn_t to C heap)."""
@inline function free_connection!(conn::Connection)
    ccall((:free_connection, _LIB), Cvoid, (Ptr{Cvoid},), conn.ptr)
    nothing
end

"""Get the operation type of a connection."""
@inline function conn_op_type(conn::Connection)::EventType
    t = ccall((:get_conn_op_type, _LIB), Cint, (Ptr{Cvoid},), conn.ptr)
    return EventType(t)
end

"""Get the file descriptor associated with a connection."""
@inline function conn_fd(conn::Connection)::Cint
    ccall((:get_conn_fd, _LIB), Cint, (Ptr{Cvoid},), conn.ptr)
end

"""Get pointer to the connection's internal buffer (`buffer_size()` bytes)."""
@inline function conn_buffer(conn::Connection)::Ptr{UInt8}
    ccall((:get_conn_buffer, _LIB), Ptr{UInt8}, (Ptr{Cvoid},), conn.ptr)
end

"""Set the operation type on a connection."""
@inline function set_conn_op!(conn::Connection, op::EventType)
    ccall((:set_conn_op_type, _LIB), Cvoid, (Ptr{Cvoid}, Cint), conn.ptr, Cint(op))
    nothing
end

"""Set the file descriptor on a connection."""
@inline function set_conn_fd!(conn::Connection, fd::Integer)
    ccall((:set_conn_fd, _LIB), Cvoid, (Ptr{Cvoid}, Cint), conn.ptr, Cint(fd))
    nothing
end

"""Configure TCP_NODELAY on an accepted client socket."""
@inline function configure_socket!(fd::Integer)
    ccall((:configure_client_socket, _LIB), Cvoid, (Cint,), Cint(fd))
    nothing
end

"""Close a raw file descriptor."""
@inline function close_fd!(fd::Integer)
    ccall(:close, Cint, (Cint,), Cint(fd))
    nothing
end

"""
    shutdown_fd!(fd)

Shut down both directions of a socket. This sends FIN immediately even while an
io_uring read is in flight on the fd (an in-flight request keeps the file
description alive, so `close` alone would not wake the peer or the read).
"""
@inline function shutdown_fd!(fd::Integer)
    ccall(:shutdown, Cint, (Cint, Cint), Cint(fd), Cint(2))  # SHUT_RDWR
    nothing
end
