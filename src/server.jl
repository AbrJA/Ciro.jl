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

# Buffer Pool to reduce allocations
const BUFFER_POOL = Vector{Vector{Vector{UInt8}}}() # Vector of Pools (one per thread)

function get_buffer(pool::Vector{Vector{UInt8}}, min_size::Int)
    if !isempty(pool)
        buf = pop!(pool)
        if length(buf) >= min_size
            return resize!(buf, min_size)
        end
        # If too small, discard and allocate new (or resize it? allocating new is often simpler for resizing up drastically)
        # Let's resize it to keep the memory active
        resize!(buf, min_size)
        return buf
    end
    return Vector{UInt8}(undef, min_size)
end

function release_buffer(pool::Vector{Vector{UInt8}}, buf::Vector{UInt8})
    # Reset size to 0 or keep it?
    # Just push it back. We limit pool size?
    if length(pool) < 128 # limit free pool size per thread
        push!(pool, buf)
    end
end


function start_server(port=8080)
    nt = Threads.nthreads()
    println("🚀 Julia io_uring backend starting on port $port with $nt threads")
    atomic_xchg!(SERVER_RUNNING, true)

    # Initialize Pools and Pending Writes
    # We can't resize consts, but we can empty and push!
    empty!(BUFFER_POOL)
    for _ in 1:nt
        push!(BUFFER_POOL, Vector{Vector{UInt8}}())
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
    # Ideally trigger wakeups on rings, but polling loops check this flag.
end

function worker_loop(port, thread_id)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    new_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)

    # Thread-local state
    # We trust thread_id is 1..N and consistent
    buffer_pool = BUFFER_POOL[thread_id]
    pending_writes = Dict{Ptr{Conn},Vector{UInt8}}()

    while SERVER_RUNNING[]
        res = Ref{Cint}(0)
        # Non-blocking poll? or blocking with timeout?
        # Current C implementation of poll_completion blocks?
        # If it blocks, we are fine as long as we yield rarely or if C yields.
        # But for strictly correct Julia handling, C shouldn't block indefinitely.
        conn_ptr = ccall((:poll_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[], pending_writes, buffer_pool)
        end
        yield()
    end

    println("  [Thread $thread_id] Exiting loop")
end

function handle_event(engine, conn_ptr, res, pending_writes, buffer_pool)
    conn_ref = unsafe_load(conn_ptr)

    if res < 0
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
        return
    end

    if conn_ref.op_type == 0 # ACCEPT
        client_fd = res

        # Queue NEXT Accept
        if SERVER_RUNNING[]
            next_accept_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
            ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, next_accept_conn)
        end

        # Transition current conn to READ
        conn_ref.fd = client_fd
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)

    elseif conn_ref.op_type == 1 # READ
        bytes_read = res
        if bytes_read <= 0
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            return
        end

        buf_ptr = Ptr{UInt8}(conn_ptr) + 8
        raw_data = unsafe_wrap(Array, buf_ptr, bytes_read)

        # Parse Request
        req_parsed = PicoHTTPParser.parse_request(raw_data)

        if req_parsed !== nothing
            handler, params = Tries.lookup(GLOBAL_ROUTER.trie, req_parsed.method, req_parsed.path)

            response = nothing
            if handler !== nothing
                # Apply Middlewares
                final_handler = handler
                for mw in reverse(GLOBAL_ROUTER.middlewares)
                    final_handler = mw(final_handler)
                end

                try
                    # Pass req_parsed directly as Request
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

        # Serialize Response Headers
        status_line = "HTTP/1.1 $(response.status) OK"
        header_lines = ""
        for (k, v) in response.headers
            header_lines *= "$k: $v\r\n"
        end

        if !haskey(response.headers, "Content-Length")
            header_lines *= "Content-Length: $(length(response.body))\r\n"
        end
        header_lines *= "\r\n" # End of headers

        # Zero-Allocation Construction using Buffer Pool
        # 1. Calculate total size
        total_len = length(status_line) + 2 + length(header_lines) + length(response.body)

        # 2. Get buffer
        full_response = get_buffer(buffer_pool, total_len)

        # 3. Copy Data
        cursor = 1

        # Status Line
        unsafe_copyto!(pointer(full_response, cursor), pointer(status_line), length(status_line))
        cursor += length(status_line)
        full_response[cursor] = UInt8('\r')
        cursor += 1
        full_response[cursor] = UInt8('\n')
        cursor += 1

        # Headers
        unsafe_copyto!(pointer(full_response, cursor), pointer(header_lines), length(header_lines))
        cursor += length(header_lines)

        # Body
        unsafe_copyto!(pointer(full_response, cursor), pointer(response.body), length(response.body))

        # anchor to protect from GC
        pending_writes[conn_ptr] = full_response

        # Pass pointer to internal data
        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
            engine, conn_ptr, pointer(full_response), total_len)

    elseif conn_ref.op_type == 2 # WRITE
        # Completion of Write

        # Free buffer and release to pool
        if haskey(pending_writes, conn_ptr)
            buf = pop!(pending_writes, conn_ptr)
            release_buffer(buffer_pool, buf)
        end

        # Check for Keep-Alive (Same as before)
        conn_ref.op_type = 1
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)
    end
end
end
