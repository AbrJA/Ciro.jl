module Servers

using Libdl
using Base.Threads
using PicoHTTPParser
using ..Types
using ..Tries
using ..Routers: GLOBAL_ROUTER

export start_server, stop_server

const lib = joinpath(@__DIR__, "../lib/ciro.so")

# Server State
const SERVER_RUNNING = Atomic{Bool}(false)

# Define the connection struct to match C
mutable struct Conn
    op_type::Int32
    fd::Int32
    buffer::NTuple{2048,UInt8}
    _padding::NTuple{32,UInt8}
end

# Connection Pool
mutable struct ConnPool
    free_conns::Vector{Ptr{Conn}}
    # Simple lock for thread safety if needed,
    # but we are designing thread-local pools mostly?
    # Actually Ciro allocates conn in C...
    # Let's make a thread-local cache of pointers.
end

const CONN_POOL = Vector{ConnPool}()

function get_conn(pool::ConnPool)
    if !isempty(pool.free_conns)
        return pop!(pool.free_conns)
    end
    return ccall((:create_connection, lib), Ptr{Conn}, ())
end

function release_conn(pool::ConnPool, conn::Ptr{Conn})
    if length(pool.free_conns) < 1000
        push!(pool.free_conns, conn)
    else
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn)
    end
end

# Buffer Pool to reduce allocations
const BUFFER_POOL = Vector{Vector{Vector{UInt8}}}() # Vector of Pools (one per thread)

function get_buffer(pool::Vector{Vector{UInt8}}, min_size::Int)
    if !isempty(pool)
        buf = pop!(pool)
        if length(buf) >= min_size
            # return resize!(buf, min_size) # Don't resize down, just use it
            # Actually we need to ensure it is at least min_size
            if length(buf) < min_size
                resize!(buf, min_size)
            end
            return buf
        end
        # If too small, discard? No, just resize up.
        resize!(buf, min_size)
        return buf
    end
    return Vector{UInt8}(undef, min_size)
end

function release_buffer(pool::Vector{Vector{UInt8}}, buf::Vector{UInt8})
    if length(pool) < 128
        push!(pool, buf)
    end
end


function start_server(port=8080)
    nt = Threads.nthreads()
    println("🚀 Julia io_uring backend starting on port $port with $nt threads")
    atomic_xchg!(SERVER_RUNNING, true)

    # Initialize Pools
    empty!(BUFFER_POOL)
    empty!(CONN_POOL)
    for _ in 1:nt
        push!(BUFFER_POOL, Vector{Vector{UInt8}}())
        push!(CONN_POOL, ConnPool(Ptr{Conn}[]))
    end

    try
        @threads for i in 1:nt
            worker_loop(port, i)
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

function worker_loop(port, thread_id)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    # Multishot Accept
    # We create one master accept connection struct and reuse/submit it?
    # No, io_uring multishot accept keeps generating CQEs.
    # We just need to submit it ONCE.
    # Wait, multishot accept produces a NEW fd for each CQE.
    # Where is the conn struct for the NEW fd?
    # The 'conn' passed to prep_multishot_accept is just the "request" handle.
    # The CQE result is the new FD.
    # We need to allocate a NEW conn struct for the new client!
    # Ah, my C implementation of queue_multishot_accept assigns `io_uring_sqe_set_data(sqe, conn)`.
    # So when an accept happens, we get `conn` back.
    # BUT, we treat `conn` as the client connection usually?
    # No, for ACCEPT, it is the acceptor context.

    # We need a dedicated acceptor connection object.
    accept_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_multishot_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, accept_conn)

    conn_pool = CONN_POOL[thread_id]
    buffer_pool = BUFFER_POOL[thread_id]
    pending_writes = Dict{Ptr{Conn},Vector{UInt8}}()

    println("  [Thread $thread_id] Loop starting")

    res = Ref{Cint}(0)

    while SERVER_RUNNING[]
        # Wait for at least one event (10ms timeout)
        conn_ptr = ccall((:wait_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}, Cint), engine, res, 10)

        events_processed = 0
        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[], pending_writes, buffer_pool, conn_pool, accept_conn)
            events_processed += 1

            # Process up to 63 more (batch 64)
            for _ in 1:63
                conn_ptr = ccall((:wait_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}, Cint), engine, res, 0)
                if conn_ptr == C_NULL
                    break
                end
                handle_event(engine, conn_ptr, res[], pending_writes, buffer_pool, conn_pool, accept_conn)
                events_processed += 1
            end
        end

        # Submit any pending reads/writes generated
        if events_processed > 0
            ccall((:submit_pending, lib), Cint, (Ptr{Cvoid},), engine)
        end

        # Don't yield if we are blocking in wait_completion?
        # wait_completion releases GIL? No, ccall blocks.
        # But we use small timeout.
        # If we didn't process anything, we should yield to allow other tasks/GC (though we are pinned mostly)
        if events_processed == 0
            yield()
        end
    end

    println("  [Thread $thread_id] Exiting loop")
end

function handle_event(engine, conn_ptr, res, pending_writes, buffer_pool, conn_pool, accept_conn)
    # Check if it is the ACCEPT cqe
    # Since we use multishot, we get the same accept_conn pointer back every time a new connection arrives!

    if conn_ptr == accept_conn
        # res contains the NEW CLIENT FD
        client_fd = res
        if client_fd < 0
            # Error in accept?
            return
        end

        # Create new connection object for this client
        new_conn = get_conn(conn_pool)
        conn_ref = unsafe_load(new_conn)
        conn_ref.fd = client_fd
        conn_ref.op_type = 1 # READ (immediately start reading)
        unsafe_store!(new_conn, conn_ref)

        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)
        return
    end

    # Normal READ/WRITE handling
    conn_ref = unsafe_load(conn_ptr)

    if res < 0
        # Error (e.g. connection reset)
        ccall(:close, Cint, (Cint,), conn_ref.fd)
        release_conn(conn_pool, conn_ptr)
        return
    end

    if conn_ref.op_type == 1 # READ
        bytes_read = res
        if bytes_read <= 0
            # EOF
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            release_conn(conn_pool, conn_ptr)
            return
        end

        buf_ptr = Ptr{UInt8}(conn_ptr) + 8 # Offset of buffer in struct (align 8?)
        # op_type(4) + fd(4) = 8 bytes. Checked struct layout?
        # struct { op_type(int), fd(int), buffer... }
        # Yes, 8 bytes offset is correct (assuming no padding between int and int)

        raw_data = unsafe_wrap(Array, buf_ptr, bytes_read)

        req_parsed = PicoHTTPParser.parse_request(raw_data)

        if req_parsed !== nothing
            handler, params = Tries.lookup(GLOBAL_ROUTER.trie, req_parsed.method, req_parsed.path)

            response = nothing
            if handler !== nothing
                # Middlewares
                final_handler = handler
                for mw in reverse(GLOBAL_ROUTER.middlewares)
                    final_handler = mw(final_handler)
                end

                try
                    res_obj = final_handler(req_parsed, params)
                    if isa(res_obj, Response)
                        response = res_obj
                    else
                        response = text(string(res_obj))
                    end
                catch e
                    @error "Handler failed" exception = (e, catch_backtrace())
                    response = Response(500, "Internal Server Error")
                end
            else
                response = Response(404, "Not Found")
            end
        else
            response = Response(400, "Bad Request")
        end

        # Generate Response Buffer (Zero Alloc)

        # Calculate size
        # Status line: "HTTP/1.1 XXX OK\r\n" -> ~17 chars
        status_len = 15 # "HTTP/1.1 200 OK" simplified
        if response.status != 200
            # We need to render status. For now simplified.
            # "HTTP/1.1 " + 3 + " OK\r\n"
        end

        # Let's use specific writing logic

        # Headers length
        headers_len = 0
        for (k, v) in response.headers
            headers_len += sizeof(k) + 2 + sizeof(v) + 2 # ": " and "\r\n"
        end

        has_len = haskey(response.headers, "Content-Length")
        if !has_len
            headers_len += 16 + 10 + 2 # "Content-Length: " + len + "\r\n" (approx)
        end
        headers_len += 2 # End of headers "\r\n"

        body_len = sizeof(response.body)
        total_len = 20 + headers_len + body_len + 100 # conservative overestimation?

        # Helper to write
        out_buf = get_buffer(buffer_pool, total_len)
        cursor = 1

        # Status
        cursor = write_bytes!(out_buf, cursor, "HTTP/1.1 ")
        cursor = write_int!(out_buf, cursor, response.status)
        cursor = write_bytes!(out_buf, cursor, " OK\r\n")

        # Headers
        for (k, v) in response.headers
            cursor = write_bytes!(out_buf, cursor, k)
            cursor = write_bytes!(out_buf, cursor, ": ")
            cursor = write_bytes!(out_buf, cursor, v)
            cursor = write_bytes!(out_buf, cursor, "\r\n")
        end

        if !has_len
            cursor = write_bytes!(out_buf, cursor, "Content-Length: ")
            cursor = write_int!(out_buf, cursor, body_len)
            cursor = write_bytes!(out_buf, cursor, "\r\n")
        end

        cursor = write_bytes!(out_buf, cursor, "\r\n")

        # Body
        if body_len > 0
            unsafe_copyto!(pointer(out_buf, cursor), pointer(response.body), body_len)
            cursor += body_len
        end

        final_len = cursor - 1

        # Anchor
        pending_writes[conn_ptr] = out_buf

        # Queue Write
        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
            engine, conn_ptr, pointer(out_buf), final_len)

    elseif conn_ref.op_type == 2 # WRITE
        # Write completed
        if haskey(pending_writes, conn_ptr)
            buf = pop!(pending_writes, conn_ptr)
            release_buffer(buffer_pool, buf)
        end

        # Keep-Alive Check?
        # For now, always close? Or always read?
        # If we read, we need to reset state.

        # Reset to READ
        conn_ref.op_type = 1
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)
    end
end

@inline function write_bytes!(buf, cursor, data::String)
    n = sizeof(data)
    unsafe_copyto!(pointer(buf, cursor), pointer(data), n)
    return cursor + n
end

@inline function write_int!(buf, cursor, val::Int)
    s = string(val) # Allocation? optimize later with itoa
    return write_bytes!(buf, cursor, s)
end

end
