"""
    Runtime

Transport-independent application runtime. Composes router, executor,
error handling and transport without depending on any I/O backend.
"""
module Runtime

using ..Interface
using ..Interface: Request, RequestContext, Response, Endpoint, RouteResult,
                   matched, not_found, method_not_allowed, Methods, text, fail,
                   route, route!, register!, freeze!, execute!, log!, intercept
import ..Interface: stop!, execute!, isasync, start_executor!, stop_executor!
import PicoHTTPParser

export AbstractTransport, TransportToken, Application, FakeTransport,
       handle, dispatch, dispatch_async, run_once!, serve!, enqueue!, response_for,
       send_response!, close!, transport_state, start_transport!, stop_transport!
export AsyncExecutor, shed_count, pending_count

include("executor.jl")

# ── Transport contract ─────────────────────────────────────────────────────

"""
    AbstractTransport

Interface for request/response transports. Implementations must provide:

- `start_transport!(transport, handler)` — begin delivering inbound requests
- `stop_transport!(transport)` — stop and clean up
- `send_response!(transport, token, response)` — answer a pending token
- `close!(transport, token)` — close the connection/stream for a token
"""
abstract type AbstractTransport end

function start_transport! end
function stop_transport! end
function send_response! end
function close! end

"""
    TransportToken

Identifies an in-flight exchange. `owner` prevents mixing tokens across
transports; `generation` prevents confusion when connections are reused.
"""
struct TransportToken
    owner::UInt64
    stream::UInt64
end

export AbstractTransport, TransportToken

# ── Application ────────────────────────────────────────────────────────────

mutable struct Application{R <: AbstractRouter, E <: AbstractExecutor,
                           L <: AbstractLogger, C <: AbstractCatcher,
                           T <: AbstractTransport}
    router    :: R
    executor  :: E
    logger    :: L
    catcher   :: C
    transport :: T
    frozen    :: Bool
    running   :: Bool
end

function Application(; router::AbstractRouter,
                     executor::AbstractExecutor = SyncExecutor(),
                     logger::AbstractLogger     = NullLogger(),
                     catcher::AbstractCatcher   = DefaultCatcher(),
                     transport::AbstractTransport = FakeTransport())
    return Application(router, executor, logger, catcher, transport, false, false)
end

function Interface.register!(app::Application, method::UInt8, pattern::String, handler)
    app.frozen && throw(ArgumentError("cannot register routes on a running application"))
    register!(app.router, method, pattern, handler)
    return app
end

function Interface.freeze!(app::Application)
    app.frozen && return app
    freeze!(app.router)
    app.frozen = true
    return app
end

# ── Dispatch ───────────────────────────────────────────────────────────────

"""
    dispatch(router, executor, catcher, request) -> Response

The single request→response pipeline: route lookup, executor invocation and
error interception. No I/O happens here. `Application` and the io_uring
`Server` both go through this function, so the transport-free test surface and
the production path can never drift apart.

The 5-argument form accepts a reusable route-capture scratch
(`Vector{Pair{Symbol,UnitRange{Int}}}`); backends pass their per-connection
scratch so routing does not allocate.
"""
function dispatch(router::AbstractRouter, executor::AbstractExecutor,
                  catcher::AbstractCatcher, request::Request)::Response
    return dispatch(router, executor, catcher, request,
                    Pair{Symbol,UnitRange{Int}}[])
end

function dispatch(router::AbstractRouter, executor::AbstractExecutor,
                  catcher::AbstractCatcher, request::Request,
                  captures::Vector{Pair{Symbol,UnitRange{Int}}})::Response
    method = Methods.from_string(request.method)
    result = route!(router, method, request.path, captures)

    not_found(result) && return fail(404, "Not Found")

    if method_not_allowed(result)
        allow_str = Methods.allow_header(result.allowed)
        return Response(405, ["Allow" => allow_str, "Content-Type" => "text/plain"],
                        "Method Not Allowed")
    end

    ctx = RequestContext(request, result.params)
    return _invoke(executor, catcher, result.handler, ctx)
end

dispatch(router::AbstractRouter, executor::AbstractExecutor,
         catcher::AbstractCatcher, request::PicoHTTPParser.Request)::Response =
    dispatch(router, executor, catcher, Request(request))

"""
    dispatch(app, request) -> Response

`Application` front-end for [`dispatch`](@ref).
"""
dispatch(app::Application, request::Request)::Response =
    dispatch(app.router, app.executor, app.catcher, request)

dispatch(app::Application, request::PicoHTTPParser.Request)::Response =
    dispatch(app, Request(request))

handle(app::Application, request) = dispatch(app, request)

"""
    dispatch_async(router, executor, catcher, request, reply) -> Bool

Callback pipeline used by I/O backends. When `executor` is synchronous this is
[`dispatch`](@ref) followed by `reply(response)`, and returns `false`. When the
executor is asynchronous the request is copied (its views must not escape the
event-loop thread), submitted to the executor, and `true` is returned; `reply`
is then invoked later, possibly from another thread. `reply` is called exactly
once either way.
"""
function dispatch_async(router::AbstractRouter, executor::AbstractExecutor,
                        catcher::AbstractCatcher, request::Request, reply)::Bool
    return dispatch_async(router, executor, catcher, request, reply,
                          Pair{Symbol,UnitRange{Int}}[])
end

function dispatch_async(router::AbstractRouter, executor::AbstractExecutor,
                        catcher::AbstractCatcher, request::Request, reply,
                        captures::Vector{Pair{Symbol,UnitRange{Int}}})::Bool
    if !isasync(executor)
        reply(dispatch(router, executor, catcher, request, captures))
        return false
    end

    method = Methods.from_string(request.method)
    result = route!(router, method, request.path, captures)

    if not_found(result)
        reply(fail(404, "Not Found"))
        return true
    end

    if method_not_allowed(result)
        allow_str = Methods.allow_header(result.allowed)
        reply(Response(405, ["Allow" => allow_str, "Content-Type" => "text/plain"],
                       "Method Not Allowed"))
        return true
    end

    # Copy-on-escape: the request's views die when the connection buffer is
    # advanced, which the caller does right after this function returns.
    ctx = copy(RequestContext(request, result.params))
    _submit_async!(executor, catcher, result.handler, ctx, reply)
    return true
end

dispatch_async(router::AbstractRouter, executor::AbstractExecutor,
               catcher::AbstractCatcher, request::PicoHTTPParser.Request,
               reply)::Bool =
    dispatch_async(router, executor, catcher, Request(request), reply)

@noinline function _invoke(executor::AbstractExecutor, catcher::AbstractCatcher,
                           endpoint, ctx::RequestContext)::Response
    try
        response = execute!(executor, endpoint, ctx)
        response isa Stream &&
            throw(ArgumentError("streaming responses require AsyncExecutor"))
        return response isa Response ? response : text(string(response))
    catch err
        return intercept(catcher,
                         err isa Exception ? err : ErrorException(string(err)),
                         ctx.request)
    end
end

# ── Serving ────────────────────────────────────────────────────────────────

function serve!(app::Application)
    app.running && throw(ArgumentError("application is already running"))
    freeze!(app)
    app.running = true
    log!(app.logger, Info, "Ciro application starting")
    try
        start_transport!(app.transport, (request, token) -> begin
            response = dispatch(app, request)
            send_response!(app.transport, token, response)
        end)
    finally
        app.running = false
        stop_transport!(app.transport)
        log!(app.logger, Info, "Ciro application stopped")
    end
    return app
end

function stop!(app::Application)
    app.running = false
    stop_transport!(app.transport)
    return app
end

# ── FakeTransport ──────────────────────────────────────────────────────────

mutable struct FakeTransport <: AbstractTransport
    pending   :: Vector{Pair{TransportToken, Request}}
    responses :: Dict{TransportToken, Response}
    closed    :: Set{TransportToken}
    state     :: Symbol
    owner     :: UInt64
    next      :: UInt64
end

const _FAKE_OWNER = Threads.Atomic{UInt64}(0)

FakeTransport() = FakeTransport(Pair{TransportToken,Request}[],
                                Dict{TransportToken,Response}(),
                                Set{TransportToken}(), :created,
                                Threads.atomic_add!(_FAKE_OWNER, UInt64(1)) + UInt64(1), 0)

transport_state(t::FakeTransport) = t.state

function _check_owner(t::FakeTransport, token::TransportToken)
    token.owner == t.owner || throw(ArgumentError("token belongs to another transport"))
    return nothing
end

"""Enqueue a request on a `FakeTransport`; returns its `TransportToken`."""
function enqueue!(t::FakeTransport, request::Request)
    t.state in (:created, :running) || throw(ArgumentError("transport is $(t.state)"))
    t.next += 1
    token = TransportToken(t.owner, t.next)
    push!(t.pending, token => request)
    return token
end

function run_once!(app::Application)
    t = app.transport::FakeTransport
    isempty(t.pending) && return false
    token, request = popfirst!(t.pending)
    _check_owner(t, token)
    token in t.closed && return true
    response = dispatch(app, request)
    send_response!(t, token, response)
    return true
end

function send_response!(t::FakeTransport, token::TransportToken, response::Response)
    _check_owner(t, token)
    haskey(t.responses, token) && throw(ArgumentError("response already sent for token"))
    token in t.closed && throw(ArgumentError("token is closed"))
    t.responses[token] = response
    return t
end

response_for(t::FakeTransport, token::TransportToken) = get(t.responses, token, nothing)

function close!(t::FakeTransport, token::TransportToken)
    _check_owner(t, token)
    push!(t.closed, token)
    return t
end

function start_transport!(t::FakeTransport, handler)
    t.state == :running && throw(ArgumentError("transport is already running"))
    t.state = :running
    while !isempty(t.pending)
        token, request = popfirst!(t.pending)
        token in t.closed && continue
        handler(request, token)
    end
    t.state = :stopped
    return t
end

function stop_transport!(t::FakeTransport)
    t.state == :running && (t.state = :stopped)
    empty!(t.pending)
    return t
end

end # module Runtime
