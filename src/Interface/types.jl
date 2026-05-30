# ══════════════════════════════════════════════════════════════════════════════
# Abstract Types — Extension Points
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractRouter

Interface for HTTP request dispatching.

Required: `route(router, method::UInt8, path::AbstractString) -> RouteResult`
Optional: `register!(router, method::UInt8, pattern::String, handler)`
"""
abstract type AbstractRouter end

function route end
function register! end

export AbstractRouter, route, register!

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
"""
struct RouteResult
    handler :: Any                          # callable or nothing
    params  :: Vector{Pair{Symbol,String}}  # captured path parameters
    allowed :: UInt8                        # method bitmask (0 = no path match)
end

# Constructors for each outcome
@inline RouteResult() = RouteResult(nothing, Pair{Symbol,String}[], 0x00)
@inline RouteResult(allowed::UInt8) = RouteResult(nothing, Pair{Symbol,String}[], allowed)
@inline RouteResult(handler, params::Vector{Pair{Symbol,String}}) = RouteResult(handler, params, 0x00)

# Status predicates — branch-free, inlinable
@inline matched(r::RouteResult)::Bool = r.handler !== nothing
@inline not_found(r::RouteResult)::Bool = r.handler === nothing && r.allowed == 0x00
@inline method_not_allowed(r::RouteResult)::Bool = r.handler === nothing && r.allowed != 0x00

export RouteResult, matched, not_found, method_not_allowed

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
