module Servers

using Libdl
using Base.Threads
using PicoHTTPParser
using ..Types
using ..StaticRouter: AbstractApp, dispatch

export start_server, stop_server

const lib = joinpath(@__DIR__, "../lib/ciro.so")

# Server State
const SERVER_RUNNING = Atomic{Bool}(false)

# Connection Pool — conn_t* is opaque, we store Ptr{Cvoid}
const CONN_POOLS = Vector{Vector{Ptr{Cvoid}}}()

function get_conn(pool::Vector{Ptr{Cvoid}})
    if !isempty(pool)
        return pop!(pool)
    end
    return ccall((:create_connection, lib), Ptr{Cvoid}, ())
end

function release_conn(pool::Vector{Ptr{Cvoid}}, conn::Ptr{Cvoid})
    if length(pool) < 1000
        push!(pool, conn)
    else
        ccall((:free_connection, lib), Cvoid, (Ptr{Cvoid},), conn)
    end
end

# Buffer Pool to reduce allocations
const BUFFER_POOLS = Vector{Vector{Vector{UInt8}}}()

function get_buffer(pool::Vector{Vector{UInt8}}, min_size::Int)
    if !isempty(pool)
        buf = pop!(pool)
        if length(buf) < min_size
            resize!(buf, min_size)
        end
        return buf
    end
    return Vector{UInt8}(undef, min_size)
end

function release_buffer(pool::Vector{Vector{UInt8}}, buf::Vector{UInt8})
    if length(pool) < 128
        push!(pool, buf)
    end
end

# --- C Accessor Helpers ---

@inline function conn_op_type(conn::Ptr{Cvoid})
    return ccall((:get_conn_op_type, lib), Cint, (Ptr{Cvoid},), conn)
end

@inline function conn_fd(conn::Ptr{Cvoid})
    return ccall((:get_conn_fd, lib), Cint, (Ptr{Cvoid},), conn)
end

@inline function conn_buffer(conn::Ptr{Cvoid})
    return ccall((:get_conn_buffer, lib), Ptr{UInt8}, (Ptr{Cvoid},), conn)
end

@inline function set_conn_op_type!(conn::Ptr{Cvoid}, t::Int)
    ccall((:set_conn_op_type, lib), Cvoid, (Ptr{Cvoid}, Cint), conn, t)
    return nothing
end

@inline function set_conn_fd!(conn::Ptr{Cvoid}, fd::Int)
    ccall((:set_conn_fd, lib), Cvoid, (Ptr{Cvoid}, Cint), conn, fd)
    return nothing
end

# --- Server ---

"""
    start_server(app::AbstractApp, port::Int=8080)

Start the HTTP server with the given application on the specified port.
Uses all available Julia threads for concurrent request handling.

# Example
```julia
@routes MyApp begin
    ("GET", "/") => index_handler
end
start_server(MyApp(), 8080)
```
"""
function start_server(app::AbstractApp, port::Int=8080)
    nt = Threads.nthreads()
    println("🚀 Ciro starting on port ", port, " with ", nt, " threads")
    atomic_xchg!(SERVER_RUNNING, true)

    # Initialize pools
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

"""
    stop_server()

Signal the server to stop accepting new connections and shut down.
"""
function stop_server()
    atomic_xchg!(SERVER_RUNNING, false)
end

function worker_loop(app::AbstractApp, port::Int, thread_id::Int)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    if engine == C_NULL
        error("[Thread ", thread_id, "] Failed to initialize engine on port ", port)
    end
    println("  [Thread ", thread_id, "] Engine initialized")

    # Multishot Accept
    accept_conn = ccall((:create_connection, lib), Ptr{Cvoid}, ())
    ccall((:queue_multishot_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, accept_conn)

    conn_pool = CONN_POOLS[thread_id]
    buffer_pool = BUFFER_POOLS[thread_id]
    pending_writes = Dict{Ptr{Cvoid},Vector{UInt8}}()

    println("  [Thread ", thread_id, "] Loop starting")

    res = Ref{Cint}(0)

    try
        while SERVER_RUNNING[]
            # Wait for at least one event (10ms timeout)
            conn_ptr = ccall((:wait_completion, lib), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cint}, Cint), engine, res, 10)

            events_processed = 0
            if conn_ptr != C_NULL
                handle_event(app, engine, conn_ptr, res[], pending_writes, buffer_pool, conn_pool, accept_conn)
                events_processed += 1

                # Process up to 63 more (batch 64)
                for _ in 1:63
                    conn_ptr = ccall((:wait_completion, lib), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cint}, Cint), engine, res, 0)
                    if conn_ptr == C_NULL
                        break
                    end
                    handle_event(app, engine, conn_ptr, res[], pending_writes, buffer_pool, conn_pool, accept_conn)
                    events_processed += 1
                end
            end

            # Submit any pending reads/writes generated
            if events_processed > 0
                ccall((:submit_pending, lib), Cint, (Ptr{Cvoid},), engine)
            end

            # Yield to allow other tasks/GC if no events
            if events_processed == 0
                yield()
            end
        end
    finally
        println("  [Thread ", thread_id, "] Cleaning up...")
        ccall((:free_connection, lib), Cvoid, (Ptr{Cvoid},), accept_conn)
        ccall((:cleanup_engine, lib), Cvoid, (Ptr{Cvoid},), engine)
        println("  [Thread ", thread_id, "] Exited")
    end
end

function handle_event(app::AbstractApp, engine, conn_ptr, res, pending_writes, buffer_pool, conn_pool, accept_conn)
    # Multishot accept: same accept_conn pointer comes back for each new connection
    if conn_ptr == accept_conn
        client_fd = res
        if client_fd < 0
            return
        end

        new_conn = get_conn(conn_pool)
        set_conn_fd!(new_conn, Int(client_fd))
        set_conn_op_type!(new_conn, 1) # READ

        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, new_conn)
        return
    end

    # Normal READ/WRITE handling
    op = conn_op_type(conn_ptr)
    fd = conn_fd(conn_ptr)

    if res < 0
        # Error (e.g. connection reset)
        ccall(:close, Cint, (Cint,), fd)
        release_conn(conn_pool, conn_ptr)
        return
    end

    if op == 1 # READ
        bytes_read = res
        if bytes_read <= 0
            # EOF
            ccall(:close, Cint, (Cint,), fd)
            release_conn(conn_pool, conn_ptr)
            return
        end

        buf_ptr = conn_buffer(conn_ptr)
        raw_data = unsafe_wrap(Array, buf_ptr, bytes_read)

        # Parse and dispatch
        response = Response(400, "Bad Request")

        req_parsed = PicoHTTPParser.parse_request(raw_data)
        if req_parsed !== nothing
            response = dispatch(app, req_parsed)
        end

        # Generate HTTP response buffer

        # Headers length
        headers_len = 0
        for (k, v) in response.headers
            headers_len += sizeof(k) + 2 + sizeof(v) + 2 # ": " and "\r\n"
        end

        has_content_length = hasheader(response, "Content-Length")
        if !has_content_length
            headers_len += 28 # "Content-Length: " + digits + "\r\n" (approx)
        end
        headers_len += 2 # End of headers "\r\n"

        body_len = sizeof(response.body)
        total_len = 20 + headers_len + body_len

        out_buf = get_buffer(buffer_pool, total_len)
        cursor = 1

        # Status line
        cursor = write_bytes!(out_buf, cursor, "HTTP/1.1 ")
        cursor = write_int!(out_buf, cursor, response.status)
        cursor = write_bytes!(out_buf, cursor, " ")
        cursor = write_bytes!(out_buf, cursor, get_status_text(response.status))
        cursor = write_bytes!(out_buf, cursor, "\r\n")

        # Headers
        for (k, v) in response.headers
            cursor = write_bytes!(out_buf, cursor, k)
            cursor = write_bytes!(out_buf, cursor, ": ")
            cursor = write_bytes!(out_buf, cursor, v)
            cursor = write_bytes!(out_buf, cursor, "\r\n")
        end

        if !has_content_length
            cursor = write_bytes!(out_buf, cursor, "Content-Length: ")
            cursor = write_int!(out_buf, cursor, body_len)
            cursor = write_bytes!(out_buf, cursor, "\r\n")
        end

        cursor = write_bytes!(out_buf, cursor, "\r\n")

        # Body
        if body_len > 0
            GC.@preserve response begin
                unsafe_copyto!(pointer(out_buf, cursor), pointer(response.body), body_len)
            end
            cursor += body_len
        end

        final_len = cursor - 1

        # Anchor buffer to prevent GC collection during async write
        pending_writes[conn_ptr] = out_buf

        # Queue Write
        GC.@preserve out_buf begin
            ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Cint),
                engine, conn_ptr, pointer(out_buf), final_len)
        end

    elseif op == 2 # WRITE
        # Write completed
        if haskey(pending_writes, conn_ptr)
            buf = pop!(pending_writes, conn_ptr)
            release_buffer(buffer_pool, buf)
        end

        # Reset to READ (keep-alive)
        set_conn_op_type!(conn_ptr, 1)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), engine, conn_ptr)
    end
end

# --- HTTP Response Helpers ---

using ..Types: hasheader

@inline function get_status_text(status::Int)
    status == 200 && return "OK"
    status == 201 && return "Created"
    status == 204 && return "No Content"
    status == 301 && return "Moved Permanently"
    status == 302 && return "Found"
    status == 304 && return "Not Modified"
    status == 400 && return "Bad Request"
    status == 401 && return "Unauthorized"
    status == 403 && return "Forbidden"
    status == 404 && return "Not Found"
    status == 405 && return "Method Not Allowed"
    status == 500 && return "Internal Server Error"
    status == 502 && return "Bad Gateway"
    status == 503 && return "Service Unavailable"
    return "Unknown"
end

@inline function write_bytes!(buf, cursor, data::String)
    n = sizeof(data)
    GC.@preserve data begin
        unsafe_copyto!(pointer(buf, cursor), pointer(data), n)
    end
    return cursor + n
end

@inline function write_bytes!(buf, cursor, data::SubString{String})
    n = sizeof(data)
    GC.@preserve data begin
        unsafe_copyto!(pointer(buf, cursor), pointer(data), n)
    end
    return cursor + n
end

# Zero-allocation integer to ASCII conversion
@inline function write_int!(buf, cursor, val::Int)
    if val == 0
        buf[cursor] = UInt8('0')
        return cursor + 1
    end

    if val < 0
        buf[cursor] = UInt8('-')
        cursor += 1
        val = -val
    end

    # Count digits
    temp = val
    n_digits = 0
    while temp > 0
        temp = div(temp, 10)
        n_digits += 1
    end

    # Write digits in reverse order
    end_cursor = cursor + n_digits
    write_pos = end_cursor - 1
    while val > 0
        buf[write_pos] = UInt8('0') + (val % 10)
        val = div(val, 10)
        write_pos -= 1
    end

    return end_cursor
end

end
