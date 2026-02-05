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

function start_server(port=8080)
    println("🚀 Julia io_uring backend starting on port $port with $(Threads.nthreads()) threads")
    atomic_xchg!(SERVER_RUNNING, true)

    # Disable default sigint handling so we can catch it
    # Base.exit_on_sigint(false)
    # Actually, better to just let user handle it or use a task.
    # For production lib, we can setup a handler.
    try
        @threads for i in 1:Threads.nthreads()
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

    while SERVER_RUNNING[]
        res = Ref{Cint}(0)
        # Block for completion? If blocking, we can't check flag easily except on wakeup.
        # But we yield.
        # Ideally use a timeout to poll.
        conn_ptr = ccall((:poll_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[])
        end
        yield()
    end

    println("  [Thread $thread_id] Exiting loop")
end

function handle_event(engine, conn_ptr, res)
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
            # Failed to parse or partial.
            # If partial, we should wait for more data... but current implementation is simple read once.
            # For now, just error or return.
            # println("Failed to parse request")
            # Cleanup handled by caller if we return
            # But we need to ensure we don't leak or close prematurely if partial.
            # Assuming simple implementation for now as per instructions.
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

        # Combine Headers part
        head_bytes = Vector{UInt8}("$status_line\r\n$header_lines\r\n")

        # Full payload = Headers + Body
        # We want to send this via queue_write without copying to the fixed buffer if possible,
        # OR just copy if small.
        # But to fix 2KB limit, we just malloc/use Julia array pointer?

        # ZERO-COPY Strategy:
        # We need to construct a single buffer or using iovec (vectored I/O).
        # Our C 'queue_write' takes (buf, len).
        # We should concatenate headers + body into a single Julia Vector{UInt8}.

        full_response = vcat(head_bytes, response.body)

        # To use Zero-Copy safe with Julia GC:
        # We use GC.@preserve around the ccall.
        # BUT ccall is async! The C function returns immediately but the I/O happens later.
        # GC.@preserve only protects during the block.
        # So we absolutely CANNOT just return.

        # Wait, liburing I/O is async.
        # Making it safe without copying to a C-owned buffer means we must ROOT the julia object
        # until the COMPLETION event comes back.

        # For this iteration, to be safe and production ready without complex object pooling/rooting maps:
        # We will use Libc.malloc to allocate a C buffer, copy data there, pass it to C,
        # and free it in the WRITE callback.
        # This is "Zero-Copy" from Julia's GC perspective (no heap corruption risk),
        # but technically one copy to C heap.
        # It removes the 2KB limit.
        # True Zero-Copy requires pinning pages or rigorous object lifecycle tracking which is complex for now.

        # Allocate C buffer
        len = length(full_response)
        c_buf = Libc.malloc(len)
        unsafe_copyto!(Ptr{UInt8}(c_buf), pointer(full_response), len)

        # We need to store this pointer so we can free it later!
        # Where? Conn struct?
        # We can add a field to Conn struct. Or simpler:
        # repurpose 'buffer' field? No it's fixed size.
        # We can treat the 'buffer' as a place to store the pointer if we cast?
        # Better: Modify Conn struct in C?
        # OR: Just for now, we allocate, and let it leak? NO.
        # We need to free it.

        # Hack for this step:
        # We will copy to the 2KB buffer if it fits.
        # If > 2KB, we truncate (as before) OR we implement the malloc strategy.
        # Let's try the malloc strategy by using the `cookie` or user_data in io_uring?
        # Our C wrapper doesn't expose it easily.

        # Let's stick to the easiest reliable fix:
        # Improve the C-side or just accept copy for now but increase buffer size?
        # User asked for "Zero-copy writes using GC.@preserve".
        # This implies they think we can just pass the pointer.
        # If we pass pointer, we MUST block until done or preserve.
        # Blocking defeats async.

        # Re-evaluating: Pure Zero-Copy in async Julia requires manual GC interaction involving `jl_gc_add_ptr_finalizer`
        # or a global Dict anchor.

        # Let's implement the Global Anchor strategy.
        # We need a unique ID for the connection/request. `conn_ptr` is good.

        PENDING_WRITES[conn_ptr] = full_response

        # Pass pointer to internal data
        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
            engine, conn_ptr, pointer(full_response), len)

        # In WRITE completion, we remove from PENDING_WRITES.

    elseif conn_ref.op_type == 2 # WRITE
        # Completion of Write

        # Remove protection
        if haskey(PENDING_WRITES, conn_ptr)
            delete!(PENDING_WRITES, conn_ptr)
        end

        # Check for Keep-Alive (Same as before)
        conn_ref.op_type = 1
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)
    end
end

# Anchor for Async Writes
const PENDING_WRITES = Dict{Ptr{Conn},Vector{UInt8}}()

end
