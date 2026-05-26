# ══════════════════════════════════════════════════════════════════════════════
# Event Loop — composable, users provide their own handler
# ══════════════════════════════════════════════════════════════════════════════
#
# The event loop is NOT a black box. Users call `run_eventloop!` with a
# handler function that receives CompletionEvents. This enables building
# arbitrary protocols (HTTP, WebSocket, gRPC, etc.) on top.
# ══════════════════════════════════════════════════════════════════════════════

"""
    run_eventloop!(handler, engine; running=Ref(true), batch_size=64)

Run the io_uring completion loop. For each completion, calls:

    handler(event::CompletionEvent)

The handler is responsible for interpreting events (accept → configure + read,
read → parse + write, write → recycle or close). This gives full control to
the protocol layer.

Exits when `running[] == false`.

# Example
```julia
engine = init_engine(8080)
accept_conn = create_connection()
queue_multishot_accept!(engine, accept_conn)

run_eventloop!(engine) do event
    if event.conn == accept_conn.ptr
        # New connection accepted
        fd = event.result
        configure_socket!(fd)
        conn = acquire!(pool)
        set_conn_fd!(conn, fd)
        set_conn_op!(conn, READ)
        queue_read!(engine, conn)
    elseif event.op_type == READ
        # Data received — parse and respond
        ...
    elseif event.op_type == WRITE
        # Write completed — recycle buffers
        ...
    end
    submit!(engine)
end
```
"""
function run_eventloop!(handler::H, engine::Engine;
                        running=Ref(true),
                        batch_size::Int=256) where {H}
    while running[]
        event = wait_completion(engine; timeout_ms=5)

        if event !== nothing
            handler(event)
            # Drain remaining completions in a batch
            for _ in 2:batch_size
                next = poll_completion(engine)
                next === nothing && break
                handler(next)
            end
            submit!(engine)
        end
        # No yield() — timeout handles CPU saving, yield adds scheduler overhead
    end
    nothing
end

"""
    run_eventloop_threaded!(handler, port; nthreads=Threads.nthreads(),
                           queue_depth=4096, running=Ref(true))

Multi-threaded event loop: spawns one io_uring engine per thread (each bound
to the same port via SO_REUSEPORT). The kernel distributes connections across
threads automatically.

Each thread runs its own `run_eventloop!`. The `handler` factory is called
per-thread and receives `(engine, tid)` to allow thread-local state.

# Example
```julia
running = Ref(true)
run_eventloop_threaded!(port=8080, running=running) do engine, tid
    pool = ConnectionPool()
    buffers = BufferPool()
    accept_conn = create_connection()
    queue_multishot_accept!(engine, accept_conn)

    return function(event::CompletionEvent)
        # per-event handler with captured thread-local pools
        ...
    end
end
```
"""
function run_eventloop_threaded!(handler_factory::F, port::Integer;
                                nthreads::Int=Threads.nthreads(),
                                queue_depth::Int=4096,
                                running=Ref(true)) where {F}
    @assert nthreads > 0 "Need at least 1 thread"

    tasks = Vector{Task}(undef, nthreads)
    for tid in 1:nthreads
        tasks[tid] = Threads.@spawn begin
            engine = init_engine(port; queue_depth)
            engine === nothing && error("[Thread $tid] Failed to init io_uring engine")

            try
                handler = handler_factory(engine, tid)
                run_eventloop!(handler, engine; running, batch_size=64)
            finally
                close_engine!(engine)
            end
        end
    end

    # Wait for all workers to finish
    for t in tasks
        wait(t)
    end
    nothing
end
