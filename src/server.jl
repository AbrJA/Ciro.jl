module Servers

using Base.Threads
using PicoHTTPParser
using ..Types
using ..Types: status_line, hasheader
using ..Router: AbstractApp, dispatch

# Configurable request size limit (default 1 MB)
const MAX_BODY_SIZE = Ref{Int}(1_048_576)

export start_server, stop_server

const lib = joinpath(@__DIR__, "..", "lib", "ciro.so")

function __init__()
    if !isfile(lib)
        @warn "Ciro native library not found at $lib. " *
              "Build it: gcc -shared -fPIC -O3 -o lib/ciro.so lib/ciro.c -luring"
    end
end

# --- Server State ---

const SERVER_RUNNING = Atomic{Bool}(false)

# --- Per-Thread Object Pools ---

const CONN_POOLS = Vector{Vector{Ptr{Cvoid}}}()
const BUFFER_POOLS = Vector{Vector{Vector{UInt8}}}()

# Max pool sizes
const MAX_CONN_POOL  = 1024
const MAX_BUF_POOL   = 256

# Max tracked fds for pending writes (per thread)
const MAX_FD_SLOTS = 65536

@inline function get_conn(pool::Vector{Ptr{Cvoid}})
    isempty(pool) || return pop!(pool)
    return ccall((:create_connection, lib), Ptr{Cvoid}, ())
end

@inline function release_conn(pool::Vector{Ptr{Cvoid}}, conn::Ptr{Cvoid})
    if length(pool) < MAX_CONN_POOL
        push!(pool, conn)
    else
        ccall((:free_connection, lib), Cvoid, (Ptr{Cvoid},), conn)
    end
end

@inline function get_buffer(pool::Vector{Vector{UInt8}}, min_size::Int)
    if !isempty(pool)
        buf = pop!(pool)
        length(buf) < min_size && resize!(buf, min_size)
        return buf
    end
    return Vector{UInt8}(undef, min_size)
end

@inline function release_buffer(pool::Vector{Vector{UInt8}}, buf::Vector{UInt8})
    length(pool) < MAX_BUF_POOL && push!(pool, buf)
end

# --- C Accessor Helpers ---

@inline conn_op_type(conn::Ptr{Cvoid}) =
    ccall((:get_conn_op_type, lib), Cint, (Ptr{Cvoid},), conn)

@inline conn_fd(conn::Ptr{Cvoid}) =
    ccall((:get_conn_fd, lib), Cint, (Ptr{Cvoid},), conn)

@inline conn_buffer(conn::Ptr{Cvoid}) =
    ccall((:get_conn_buffer, lib), Ptr{UInt8}, (Ptr{Cvoid},), conn)

@inline function set_conn_op_type!(conn::Ptr{Cvoid}, t::Int)
    ccall((:set_conn_op_type, lib), Cvoid, (Ptr{Cvoid}, Cint), conn, t)
end

@inline function set_conn_fd!(conn::Ptr{Cvoid}, fd::Int)
    ccall((:set_conn_fd, lib), Cvoid, (Ptr{Cvoid}, Cint), conn, fd)
end

# --- Pending Write Tracker (flat array indexed by fd, avoids Dict allocation) ---

mutable struct PendingWrites
    slots::Vector{Union{Nothing, Vector{UInt8}}}
    close_after::BitVector
end

PendingWrites(max_fd::Int) = PendingWrites(
    Vector{Union{Nothing, Vector{UInt8}}}(nothing, max_fd),
    falses(max_fd)
)

@inline function pw_set!(pw::PendingWrites, fd::Integer, buf::Vector{UInt8})
    idx = Int(fd) + 1  # fd is 0-based
    if idx > length(pw.slots)
        resize!(pw.slots, max(idx, length(pw.slots) * 2))
        for i in (length(pw.slots) - (idx - length(pw.slots))):length(pw.slots)
            # already initialized to nothing by resize for Union types
        end
    end
    @inbounds pw.slots[idx] = buf
end

@inline function pw_pop!(pw::PendingWrites, fd::Integer)::Union{Nothing, Vector{UInt8}}
    idx = Int(fd) + 1
    idx > length(pw.slots) && return nothing
    @inbounds buf = pw.slots[idx]
    @inbounds pw.slots[idx] = nothing
    return buf
end

# --- Server API ---

function start_server(app::AbstractApp, port::Int=8080)
    nt = Threads.nthreads()
    println("🚀 Ciro starting on port ", port, " with ", nt, " threads")
    atomic_xchg!(SERVER_RUNNING, true)

    empty!(BUFFER_POOLS)
    empty!(CONN_POOLS)
    for _ in 1:nt
        push!(BUFFER_POOLS, Vector{Vector{UInt8}}())
        push!(CONN_POOLS, Vector{Ptr{Cvoid}}())
    end

    try
        @threads for i in 1:nt
            worker_loop(app, port, i)
        end
    catch e
        if e isa InterruptException
            println("\n🛑 Server stopping...")
            stop_server()
        else
            rethrow(e)
        end
    end
end

function stop_server()
    atomic_xchg!(SERVER_RUNNING, false)
end

# --- Worker Loop ---

function worker_loop(app::AbstractApp, port::Int, thread_id::Int)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    if engine == C_NULL
        error("[Thread $thread_id] Failed to initialize engine on port $port")
    end
    println("  [Thread ", thread_id, "] Engine ready")

    # Multishot Accept
    accept_conn = ccall((:create_connection, lib), Ptr{Cvoid}, ())
    ccall((:queue_multishot_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, accept_conn)

    conn_pool = CONN_POOLS[thread_id]
    buffer_pool = BUFFER_POOLS[thread_id]
    pending = PendingWrites(MAX_FD_SLOTS)

    res = Ref{Cint}(0)
    batch_size = 64

    try
        while SERVER_RUNNING[]
            conn_ptr = ccall((:wait_completion, lib), Ptr{Cvoid},
                (Ptr{Cvoid}, Ref{Cint}, Cint), engine, res, 10)

            events = 0
            if conn_ptr != C_NULL
                try
                    handle_event(app, engine, conn_ptr, res[], pending, buffer_pool, conn_pool, accept_conn)
                catch ex
                    @error "handle_event error" exception=(ex, catch_backtrace())
                end
                events += 1

                for _ in 2:batch_size
                    conn_ptr = ccall((:poll_completion, lib), Ptr{Cvoid},
                        (Ptr{Cvoid}, Ref{Cint}), engine, res)
                    conn_ptr == C_NULL && break
                    try
                        handle_event(app, engine, conn_ptr, res[], pending, buffer_pool, conn_pool, accept_conn)
                    catch ex
                        @error "handle_event error" exception=(ex, catch_backtrace())
                    end
                    events += 1
                end
            end

            if events > 0
                ccall((:submit_pending, lib), Cint, (Ptr{Cvoid},), engine)
            else
                yield()
            end
        end
    finally
        println("  [Thread ", thread_id, "] Cleaning up...")
        ccall((:free_connection, lib), Cvoid, (Ptr{Cvoid},), accept_conn)
        ccall((:cleanup_engine, lib), Cvoid, (Ptr{Cvoid},), engine)
    end
end

# --- Event Handler ---

function handle_event(app, engine, conn_ptr, res, pending, buffer_pool, conn_pool, accept_conn)
    # Multishot accept
    if conn_ptr == accept_conn
        client_fd = res
        client_fd < 0 && return

        # Set TCP_NODELAY for low-latency responses
        ccall((:configure_client_socket, lib), Cvoid, (Cint,), client_fd)

        new_conn = get_conn(conn_pool)
        set_conn_fd!(new_conn, Int(client_fd))
        set_conn_op_type!(new_conn, 1)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, new_conn)
        return
    end

    op = conn_op_type(conn_ptr)
    fd = conn_fd(conn_ptr)

    if res < 0
        ccall(:close, Cint, (Cint,), fd)
        release_conn(conn_pool, conn_ptr)
        return
    end

    if op == 1  # READ
        handle_read(app, engine, conn_ptr, fd, res, pending, buffer_pool, conn_pool)
    elseif op == 2  # WRITE
        handle_write(engine, conn_ptr, fd, pending, buffer_pool, conn_pool)
    end
end

function handle_read(app, engine, conn_ptr, fd, bytes_read, pending, buffer_pool, conn_pool)
    if bytes_read <= 0
        ccall(:close, Cint, (Cint,), fd)
        release_conn(conn_pool, conn_ptr)
        return
    end

    buf_ptr = conn_buffer(conn_ptr)
    raw_data = unsafe_wrap(Array, buf_ptr, bytes_read)

    # Parse & dispatch
    req_parsed = PicoHTTPParser.parse_request(raw_data)

    # Check request size limit
    response = if req_parsed === nothing
        Response(400, "Bad Request")
    elseif bytes_read > MAX_BODY_SIZE[]
        Response(413, "Request Entity Too Large")
    else
        dispatch(app, req_parsed)
    end

    # Check Connection: close header
    should_close = false
    if req_parsed !== nothing
        for (k, v) in req_parsed.headers
            if String(k) == "Connection" && String(v) == "close"
                should_close = true; break
            end
        end
    end

    # Serialize HTTP response
    out_buf = serialize_response(response, buffer_pool)
    final_len = length(out_buf)

    # Track buffer and close flag
    pw_set!(pending, fd, out_buf)
    if should_close
        idx = Int(fd) + 1
        idx > length(pending.close_after) && resize!(pending.close_after, idx)
        pending.close_after[idx] = true
    end

    GC.@preserve out_buf begin
        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Cint),
            engine, conn_ptr, pointer(out_buf), final_len)
    end
end

function handle_write(engine, conn_ptr, fd, pending, buffer_pool, conn_pool)
    buf = pw_pop!(pending, fd)
    buf !== nothing && release_buffer(buffer_pool, buf)

    # Check Connection: close flag
    idx = Int(fd) + 1
    if idx <= length(pending.close_after) && pending.close_after[idx]
        pending.close_after[idx] = false
        ccall(:close, Cint, (Cint,), fd)
        release_conn(conn_pool, conn_ptr)
        return
    end

    # Keep-alive: queue next read
    set_conn_op_type!(conn_ptr, 1)
    ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, conn_ptr)
end

# --- Response Serialization ---

function serialize_response(response::Response, buffer_pool::Vector{Vector{UInt8}})
    sl = status_line(response.status)
    sl_len = sizeof(sl)

    # Calculate total size
    headers_len = 0
    for (k, v) in response.headers
        headers_len += sizeof(k) + 2 + sizeof(v) + 2  # "key: value\r\n"
    end

    has_cl = hasheader(response, "Content-Length")
    body_len = length(response.body)

    if !has_cl
        headers_len += 16 + ndigits(body_len) + 2  # "Content-Length: N\r\n"
    end
    headers_len += 2  # final "\r\n"

    total = sl_len + headers_len + body_len
    buf = get_buffer(buffer_pool, total)
    cursor = 1

    # Status line (const String reference — zero allocation)
    cursor = _write_str!(buf, cursor, sl)

    # Headers
    for (k, v) in response.headers
        cursor = _write_str!(buf, cursor, k)
        cursor = _write_lit!(buf, cursor, ": ")
        cursor = _write_str!(buf, cursor, v)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    if !has_cl
        cursor = _write_lit!(buf, cursor, "Content-Length: ")
        cursor = _write_int!(buf, cursor, body_len)
        cursor = _write_lit!(buf, cursor, "\r\n")
    end

    cursor = _write_lit!(buf, cursor, "\r\n")

    # Body
    if body_len > 0
        GC.@preserve response begin
            unsafe_copyto!(pointer(buf, cursor), pointer(response.body), body_len)
        end
        cursor += body_len
    end

    # Trim to exact size
    resize!(buf, cursor - 1)
    return buf
end

# --- Zero-Copy Write Helpers ---

@inline function _write_str!(buf::Vector{UInt8}, cursor::Int, s::String)
    n = sizeof(s)
    GC.@preserve s unsafe_copyto!(pointer(buf, cursor), pointer(s), n)
    return cursor + n
end

@inline function _write_str!(buf::Vector{UInt8}, cursor::Int, s::SubString{String})
    n = sizeof(s)
    GC.@preserve s unsafe_copyto!(pointer(buf, cursor), pointer(s), n)
    return cursor + n
end

@inline function _write_lit!(buf::Vector{UInt8}, cursor::Int, s::String)
    n = sizeof(s)
    GC.@preserve s unsafe_copyto!(pointer(buf, cursor), pointer(s), n)
    return cursor + n
end

@inline function _write_int!(buf::Vector{UInt8}, cursor::Int, val::Int)
    val == 0 && (@inbounds buf[cursor] = UInt8('0'); return cursor + 1)

    # Count digits
    n = ndigits(val)
    pos = cursor + n - 1
    v = val
    while v > 0
        @inbounds buf[pos] = UInt8('0') + (v % 10)
        v = div(v, 10)
        pos -= 1
    end
    return cursor + n
end

@inline function ndigits(n::Int)
    n <= 0 && return 1
    d = 0
    while n > 0
        n = div(n, 10)
        d += 1
    end
    return d
end

end
