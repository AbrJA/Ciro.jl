# ══════════════════════════════════════════════════════════════════════════════
# AsyncExecutor — run slow handlers off the event-loop thread
#
# A bounded pool of worker tasks executes handlers (model inference, blocking
# work). The dispatch call returns immediately; the response is delivered
# through the adapter's reply callback, which is thread-safe.
#
# The request/context is COPIED before crossing the worker boundary (the
# zero-copy views are only valid on the event-loop thread), following the
# copy-on-escape rule. Requests beyond `max_pending` are shed with 503 +
# `Retry-After`.
# ══════════════════════════════════════════════════════════════════════════════

"""
    AsyncExecutor(; worker_threads=2, max_pending=256)

Runs handlers on a bounded pool of worker tasks so slow handlers do not block
an event-loop thread. `Server` starts and stops the workers; requests are
copied before they cross the boundary. When more than `max_pending` handlers
are queued or running, new requests are shed with `503 Service Unavailable`
and `Retry-After: 1`.

Workers are ordinary Julia tasks, so run the server with more threads than
`nworkers` (for example `julia --threads=4` with `nworkers=2`) to reserve
capacity for handlers. `shed_count`/`pending_count` expose the executor's
counters for metrics and tests.
"""
mutable struct AsyncExecutor <: AbstractExecutor
    jobs        :: Channel{Tuple{Any,RequestContext,Any,Any}}
    running     :: Threads.Atomic{Bool}
    pending     :: Threads.Atomic{Int}
    max_pending :: Int
    shed        :: Threads.Atomic{Int}
    nworkers    :: Int
    workers     :: Vector{Task}
end

_jobs_channel() = Channel{Tuple{Any,RequestContext,Any,Any}}(Inf)

function AsyncExecutor(; worker_threads::Int=2, max_pending::Int=256)
    worker_threads > 0 || throw(ArgumentError("worker_threads must be positive"))
    max_pending > 0 || throw(ArgumentError("max_pending must be positive"))
    return AsyncExecutor(_jobs_channel(), Threads.Atomic{Bool}(false),
                         Threads.Atomic{Int}(0), max_pending,
                         Threads.Atomic{Int}(0), worker_threads, Task[])
end

isasync(::AsyncExecutor)::Bool = true

"Number of requests shed with 503 since startup."
shed_count(ex::AsyncExecutor)::Int = ex.shed[]

"Number of handlers queued or running."
pending_count(ex::AsyncExecutor)::Int = ex.pending[]

function start_executor!(ex::AsyncExecutor)
    ex.running[] && return ex
    jobs = _jobs_channel()
    ex.jobs = jobs
    ex.pending[] = 0
    ex.running[] = true
    ex.workers = [Threads.@spawn _async_worker(ex, jobs) for _ in 1:ex.nworkers]
    return ex
end

"""Stop accepting jobs and close the queue. Running handlers are not awaited;
hung handlers must not be able to wedge server shutdown."""
function stop_executor!(ex::AsyncExecutor)
    ex.running[] || return ex
    ex.running[] = false
    isopen(ex.jobs) && close(ex.jobs)
    empty!(ex.workers)
    return ex
end

function _async_worker(ex::AsyncExecutor, jobs::Channel)
    while ex.running[]
        job = try
            take!(jobs)
        catch
            break
        end
        handler, ctx, catcher, reply = job
        response = try
            # Workers live across many `start!`/`stop!` cycles, so run user
            # code in the latest world instead of the one captured at spawn.
            r = Base.invokelatest(handler, ctx)
            # `Stream` is handed to the adapter, which frames chunks.
            r isa Stream ? r : (r isa Response ? r : text(string(r)))
        catch err
            Base.invokelatest(intercept, catcher,
                              err isa Exception ? err : ErrorException(string(err)),
                              ctx.request)
        end
        Threads.atomic_sub!(ex.pending, 1)
        try
            Base.invokelatest(reply, response)
        catch
        end
    end
    return
end

@noinline _shed_response()::Response =
    Response(503, ["Content-Type" => "text/plain", "Retry-After" => "1"],
             "Service Unavailable")

function _submit_async!(ex::AsyncExecutor, catcher, handler, ctx::RequestContext, reply)
    if !ex.running[]
        Threads.atomic_add!(ex.shed, 1)
        reply(_shed_response())
        return false
    end
    queued = Threads.atomic_add!(ex.pending, 1) + 1
    if queued > ex.max_pending
        Threads.atomic_sub!(ex.pending, 1)
        Threads.atomic_add!(ex.shed, 1)
        reply(_shed_response())
        return false
    end
    put!(ex.jobs, (handler, ctx, catcher, reply))
    return true
end

# Application/FakeTransport drives executors synchronously; async needs the
# adapter callback path (Server), so fail loudly instead of silently blocking.
execute!(::AsyncExecutor, endpoint, ctx::RequestContext) =
    error("AsyncExecutor requires the callback dispatch path; use Server (or SyncExecutor with Application)")
