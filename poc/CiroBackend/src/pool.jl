# ══════════════════════════════════════════════════════════════════════════════
# Resource Pools — zero-allocation hot paths via pre-allocated flat arrays
# ══════════════════════════════════════════════════════════════════════════════

# ── Connection Pool ─────────────────────────────────────────────────────────

"""
    ConnectionPool(; max_size=1024)

Thread-local pool of pre-allocated conn_t structs.
Avoids malloc/free on every request in steady state.
"""
struct ConnectionPool
    pool :: Vector{Connection}
    max  :: Int
end

ConnectionPool(; max_size::Int=1024) = ConnectionPool(Vector{Connection}(), max_size)

"""Acquire a connection from the pool (or allocate a new one)."""
@inline function acquire!(pool::ConnectionPool)::Connection
    isempty(pool.pool) && return create_connection()
    return pop!(pool.pool)
end

"""Return a connection to the pool (or free it if pool is full)."""
@inline function release!(pool::ConnectionPool, conn::Connection)
    if length(pool.pool) < pool.max
        push!(pool.pool, conn)
    else
        free_connection!(conn)
    end
    nothing
end

# ── Buffer Pool ─────────────────────────────────────────────────────────────

"""
    BufferPool(; max_size=256, buffer_capacity=65536)

Thread-local pool of reusable byte buffers for serialization.
Avoids allocation on every response write.
"""
struct BufferPool
    pool     :: Vector{Vector{UInt8}}
    max      :: Int
    capacity :: Int
end

BufferPool(; max_size::Int=256, buffer_capacity::Int=65536) =
    BufferPool(Vector{Vector{UInt8}}(), max_size, buffer_capacity)

"""Acquire a buffer from the pool (or allocate a new one)."""
@inline function acquire!(pool::BufferPool)::Vector{UInt8}
    if !isempty(pool.pool)
        buf = pop!(pool.pool)
        # Ensure minimum capacity
        length(buf) < pool.capacity && resize!(buf, pool.capacity)
        return buf
    end
    return Vector{UInt8}(undef, pool.capacity)
end

"""Return a buffer to the pool."""
@inline function release!(pool::BufferPool, buf::Vector{UInt8})
    length(pool.pool) < pool.max && push!(pool.pool, buf)
    nothing
end

# ── Pending Writes Tracker ──────────────────────────────────────────────────
# Flat array indexed by fd — O(1) lookup, no hashing.

"""
    PendingWrites(; max_fd=65536)

Tracks in-flight write buffers by file descriptor.
Ensures buffers stay alive until io_uring write completion.
Also tracks which connections should be closed after write.
"""
struct PendingWrites
    buffers     :: Vector{Union{Nothing, Vector{UInt8}}}
    close_after :: BitVector
end

PendingWrites(; max_fd::Int=65536) =
    PendingWrites(Vector{Union{Nothing, Vector{UInt8}}}(nothing, max_fd), falses(max_fd))

"""Store a buffer for an in-flight write on `fd`."""
@inline function set_pending!(pw::PendingWrites, fd::Integer, buf::Vector{UInt8})
    idx = Int(fd) + 1
    if idx > length(pw.buffers)
        new_len = max(idx, length(pw.buffers) * 2)
        resize!(pw.buffers, new_len)
        resize!(pw.close_after, new_len)
    end
    @inbounds pw.buffers[idx] = buf
    nothing
end

"""Retrieve and clear the pending buffer for `fd`."""
@inline function pop_pending!(pw::PendingWrites, fd::Integer)::Union{Nothing, Vector{UInt8}}
    idx = Int(fd) + 1
    idx > length(pw.buffers) && return nothing
    @inbounds buf = pw.buffers[idx]
    @inbounds pw.buffers[idx] = nothing
    return buf
end

"""Mark that a connection should be closed after its pending write completes."""
@inline function mark_close!(pw::PendingWrites, fd::Integer)
    idx = Int(fd) + 1
    if idx > length(pw.close_after)
        new_len = max(idx, length(pw.close_after) * 2)
        resize!(pw.close_after, new_len)
    end
    @inbounds pw.close_after[idx] = true
    nothing
end

"""Check and clear the close-after flag for `fd`."""
@inline function should_close!(pw::PendingWrites, fd::Integer)::Bool
    idx = Int(fd) + 1
    idx > length(pw.close_after) && return false
    @inbounds val = pw.close_after[idx]
    @inbounds pw.close_after[idx] = false
    return val
end
