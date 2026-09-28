# ══════════════════════════════════════════════════════════════════════════════
# Abstract Types — Extension Points
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractRouter

Interface for HTTP request dispatching.

Required: `route(router, method::UInt8, path::AbstractString) -> RouteResult`
Optional: `register!(router, method::UInt8, pattern::String, handler)`,
`route!(router, method, path, captures) -> RouteResult`
"""
abstract type AbstractRouter end

function route end
function register! end

"""
    route!(router, method::UInt8, path, captures) -> RouteResult

Like [`route`](@ref), but captures path parameters into the caller-provided
`captures` scratch. The served path passes a reused
`Vector{Pair{Symbol,UnitRange{Int}}}` (ranges into `path`), so routing does not
allocate; `route` itself passes a string vector to return owned, self-contained
params. The default implementation ignores `captures` and delegates to `route`;
`Trie` implements it natively.
"""
route!(router::AbstractRouter, method::UInt8, path::AbstractString, captures) =
    route(router, method, path)

"""Freeze a component before serving; mutable implementations may override it."""
function freeze! end
freeze!(::AbstractRouter) = nothing

export AbstractRouter, route, route!, register!, freeze!

"""
    AbstractLogger

System-level logger (startup/shutdown/errors). NOT for per-request logging.
Required: `log!(logger, level::Severity, msg::String)`
"""
abstract type AbstractLogger end

@enum Severity Debug=1 Info Warn Error Fatal

function log! end

export AbstractLogger, Severity, Debug, Info, Warn, Error, Fatal, log!

"""
    AbstractCatcher

Converts exceptions to HTTP responses safely.
Required: `intercept(catcher, err::Exception, req) -> Response`
"""
abstract type AbstractCatcher end

function intercept end

export AbstractCatcher, intercept

# ══════════════════════════════════════════════════════════════════════════════
# Backend Abstraction — enables alternative I/O backends
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractBackend

Interface for I/O backends (io_uring, epoll, kqueue, etc.).

Required:
- `start_backend!(backend, handler_factory, port; kwargs...)` — start accepting connections
- `stop_backend!(backend)` — stop and clean up

The default implementation is `IOUringBackend` (Linux only, kernel ≥ 5.19).
"""
abstract type AbstractBackend end

function start_backend! end
function stop_backend! end

export AbstractBackend, start_backend!, stop_backend!

# ══════════════════════════════════════════════════════════════════════════════
# Route Result — Type-stable return from route()
# ══════════════════════════════════════════════════════════════════════════════

"""
    RouteResult

Single concrete return type for `route()`. Encodes three outcomes without
type instability:

- **Match**: `handler !== nothing`
- **404 Not Found**: `handler === nothing && allowed == 0x00`
- **405 Method Not Allowed**: `handler === nothing && allowed != 0x00`

The `allowed` field is a bitmask of method IDs that DO exist for the path.
This enables generating the `Allow` header without allocation.

`params` is `()` when nothing was captured; otherwise it is an iterable of
`name => value` pairs — `name => UnitRange` byte ranges into the routed path
for a Trie match, or the values a custom router supplied. Always read values
through [`param`](@ref), which resolves ranges against `ctx.request.path`.
"""
struct RouteResult
    handler :: Any          # callable or nothing
    params  :: Any          # () | name => value pairs
    allowed :: UInt8        # method bitmask (0 = no path match)
end

const _NO_PARAMS = ()

# Constructors for each outcome
@inline RouteResult() = RouteResult(nothing, _NO_PARAMS, 0x00)
@inline RouteResult(allowed::UInt8) = RouteResult(nothing, _NO_PARAMS, allowed)
@inline RouteResult(handler, params) = RouteResult(handler, params, 0x00)

# Status predicates — branch-free, inlinable
@inline matched(r::RouteResult)::Bool = r.handler !== nothing
@inline not_found(r::RouteResult)::Bool = r.handler === nothing && r.allowed == 0x00
@inline method_not_allowed(r::RouteResult)::Bool = r.handler === nothing && r.allowed != 0x00

export RouteResult, matched, not_found, method_not_allowed

# ── Handler execution ───────────────────────────────────────────────────────

"""Execution policy for route endpoints."""
abstract type AbstractExecutor end

"""Run handlers synchronously on the current worker."""
struct SyncExecutor <: AbstractExecutor end

function execute! end

@inline execute!(::SyncExecutor, endpoint, context::RequestContext) =
    endpoint(context)

"Whether `execute!` may complete after the dispatch call returns."
isasync(::AbstractExecutor)::Bool = false

"Start executor-owned workers (no-op for synchronous executors)."
start_executor!(::AbstractExecutor) = nothing

"Stop executor-owned workers (no-op for synchronous executors)."
stop_executor!(::AbstractExecutor) = nothing

export AbstractExecutor, SyncExecutor, execute!, isasync, start_executor!, stop_executor!

"""
    stop!(component)

Request a graceful stop of a running component (a `Server` or an `Application`).
"""
function stop! end

export stop!

# ══════════════════════════════════════════════════════════════════════════════
# Default Implementations
# ══════════════════════════════════════════════════════════════════════════════

"""Silent logger — all calls optimize away."""
struct NullLogger <: AbstractLogger end
@inline log!(::NullLogger, ::Severity, ::String) = nothing

"""Default error handler — never exposes internals (OWASP safe)."""
struct DefaultCatcher <: AbstractCatcher end
@inline function intercept(::DefaultCatcher, ::Exception, _)
    fail(500, "Internal Server Error")
end

export NullLogger, DefaultCatcher
