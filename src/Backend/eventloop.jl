# ══════════════════════════════════════════════════════════════════════════════
# Event Loop — composable, users provide their own handler
# ══════════════════════════════════════════════════════════════════════════════
#
# The event loop is NOT a black box. Users call `run_eventloop!` with a
# handler function that receives CompletionEvents. This enables building
# arbitrary protocols (HTTP, WebSocket, gRPC, etc.) on top.
# ══════════════════════════════════════════════════════════════════════════════

"""
    run_eventloop!(handler, engine; running=Ref(true), batch_size=64, on_tick=nothing)

Run the io_uring completion loop. For each completion, calls:

    handler(event::CompletionEvent)

Additionally, after every loop iteration (including timeouts), calls
`on_tick()` if provided. `on_tick` enables deadline sweeps and heartbeats
without a second task.

The handler is responsible for interpreting events (accept → configure + read,
read → parse + write, write → recycle or close). Exits when `running[] == false`.
"""
function run_eventloop!(handler::H, engine::Engine;
                        running::Threads.Atomic{Bool}=Threads.Atomic{Bool}(true),
                        batch_size::Int=64,
                        on_tick::T=nothing) where {H, T}
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

        on_tick === nothing || on_tick()
    end
    nothing
end

"""
    run_eventloop_threaded!(handler_factory, port; nthreads=Threads.nthreads(),
                            queue_depth=4096, host="0.0.0.0", backlog=8192,
                            running=Threads.Atomic{Bool}(true))

Multi-threaded event loop: spawns one io_uring engine per thread (each bound to
the same port via SO_REUSEPORT). The kernel distributes connections across
engines.

The `handler_factory` is called once per thread as `handler_factory(engine, tid)`
and must return a tuple `(handler, on_tick)`, where `handler` is called for each
`CompletionEvent` and `on_tick` (may be `nothing`) is called after every loop
iteration.

# Example
```julia
running = Threads.Atomic{Bool}(true)
run_eventloop_threaded!(port=8080, running=running) do engine, tid
    pool = ConnectionPool()
    accept_conn = create_connection()
    queue_multishot_accept!(engine, accept_conn)

    handler = event -> begin
        # per-event handling with captured thread-local state
    end
    on_tick = () -> nothing
    return handler, on_tick
end
```
"""
function run_eventloop_threaded!(handler_factory::F, port::Integer;
                                nthreads::Int=Threads.nthreads(),
                                queue_depth::Int=4096,
                                host::AbstractString="0.0.0.0",
                                backlog::Int=8192,
                                running::Threads.Atomic{Bool}=Threads.Atomic{Bool}(true)) where {F}
    @assert nthreads > 0 "Need at least 1 thread"

    tasks = Vector{Task}(undef, nthreads)
    for tid in 1:nthreads
        tasks[tid] = Threads.@spawn begin
            engine = init_engine(port; host, backlog, queue_depth)
            engine === nothing && error("[Thread $tid] Failed to init io_uring engine")

            try
                handler, on_tick = handler_factory(engine, tid)
                run_eventloop!(handler, engine; running, on_tick)
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
