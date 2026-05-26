# ══════════════════════════════════════════════════════════════════════════════
# Core Types — all concrete, trim=safe
# ══════════════════════════════════════════════════════════════════════════════

"""I/O operation type matching C enum: ACCEPT=0, READ=1, WRITE=2"""
@enum EventType::Cint begin
    ACCEPT = 0
    READ   = 1
    WRITE  = 2
end

"""
    CompletionEvent

Result of a completed io_uring operation.
Zero-allocation: lives on the stack, no heap pointers.
"""
struct CompletionEvent
    conn    :: Ptr{Cvoid}   # Pointer to conn_t (opaque C struct)
    result  :: Cint         # Bytes read/written, or fd for accept, or negative errno
    op_type :: EventType    # What operation completed
end

"""
    Engine

Wraps a single io_uring instance + server socket.
One per thread — never shared across threads.
"""
mutable struct Engine
    ptr  :: Ptr{Cvoid}   # struct engine_state*
    port :: Cint
    @inline function Engine(ptr::Ptr{Cvoid}, port::Integer)
        e = new(ptr, Cint(port))
        return e
    end
end

"""
    Connection

Opaque handle to a conn_t C struct.
Managed via ConnectionPool — never allocate directly in hot paths.
"""
struct Connection
    ptr :: Ptr{Cvoid}
end

Base.:(==)(a::Connection, b::Connection) = a.ptr == b.ptr
