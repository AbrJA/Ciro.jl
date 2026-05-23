# ══════════════════════════════════════════════════════════════════════════════
# Connection — thin wrapper over conn_t* with ccall accessors
# ══════════════════════════════════════════════════════════════════════════════

const BUFFER_SIZE = 8192  # Must match C BUFFER_SIZE

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

"""Get pointer to the connection's internal buffer (BUFFER_SIZE bytes)."""
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
