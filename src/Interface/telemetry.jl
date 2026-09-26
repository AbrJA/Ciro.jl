# ══════════════════════════════════════════════════════════════════════════════
# Telemetry — per-request observation (metrics, access logs, tracing)
#
# The HTTP layer reports every parsed request, every response it queues, every
# byte it reads, and the Runtime reports intercepted exceptions (through the
# adapter's catcher wrapper). `NullTelemetry` is the default and compiles away;
# `ServerMetrics` and `AccessLog` are ready-made implementations.
# ══════════════════════════════════════════════════════════════════════════════

using Dates: now

"""
    AbstractTelemetry

Per-request observer. Implementations may override any of:

- `telemetry_request!(t, method::UInt8, path, minor_version::UInt8)` — a request
  head was parsed; `path` is a view, valid only during the call.
- `telemetry_response!(t, method, path, status::Int, bytes::Int, elapsed::Float64)`
  — a response is on the wire (for streams: when it ends). Called once per
  response, including protocol errors (400/413/431/501) and shed requests.
- `telemetry_read!(t, bytes::Int)` — bytes read from a connection.
- `telemetry_exception!(t)` — the catcher intercepted a handler exception.

Traits: `telemetry_active(t)` (false lets hot paths skip bookkeeping) and
`telemetry_capture_path(t)` (true when the observer keeps the path beyond the
request, e.g. access logs). Handlers run with `Server(; telemetry=...)`.
"""
abstract type AbstractTelemetry end

function telemetry_request! end
function telemetry_response! end
function telemetry_read! end
function telemetry_exception! end

# Defaults: an observer only implements the callbacks it cares about.
telemetry_request!(::AbstractTelemetry, ::UInt8, path, ::UInt8) = nothing
telemetry_response!(::AbstractTelemetry, ::UInt8, path, ::Int, ::Int, ::Float64) = nothing
telemetry_read!(::AbstractTelemetry, ::Int) = nothing
telemetry_exception!(::AbstractTelemetry) = nothing

"Whether this observer does any work (lets hot paths skip bookkeeping)."
telemetry_active(::AbstractTelemetry)::Bool = true

"Whether request paths must be copied for this observer (access logs)."
telemetry_capture_path(::AbstractTelemetry)::Bool = true

"""
    NullTelemetry

Default observer: every callback is a no-op and `telemetry_active` is `false`,
so the instrumentation branches disappear in compiled code.
"""
struct NullTelemetry <: AbstractTelemetry end

telemetry_active(::NullTelemetry)::Bool = false
telemetry_capture_path(::NullTelemetry)::Bool = false

"""
    ServerMetrics <: AbstractTelemetry

Atomic request counters, safe to read from any task while the server runs.
Enable with `Server(; telemetry=ServerMetrics())` and read a consistent
snapshot with [`metrics_snapshot`](@ref). Paths are not captured.
"""
struct ServerMetrics <: AbstractTelemetry
    requests   :: Threads.Atomic{Int}
    responses  :: Threads.Atomic{Int}
    status_1xx :: Threads.Atomic{Int}
    status_2xx :: Threads.Atomic{Int}
    status_3xx :: Threads.Atomic{Int}
    status_4xx :: Threads.Atomic{Int}
    status_5xx :: Threads.Atomic{Int}
    exceptions :: Threads.Atomic{Int}
    bytes_in   :: Threads.Atomic{Int}
    bytes_out  :: Threads.Atomic{Int}
end

@inline _counter() = Threads.Atomic{Int}(0)

ServerMetrics() = ServerMetrics(_counter(), _counter(), _counter(), _counter(),
                                _counter(), _counter(), _counter(), _counter(),
                                _counter(), _counter())

telemetry_capture_path(::ServerMetrics)::Bool = false

telemetry_request!(m::ServerMetrics, ::UInt8, path, ::UInt8) =
    (Threads.atomic_add!(m.requests, 1); nothing)

telemetry_read!(m::ServerMetrics, bytes::Int) =
    (Threads.atomic_add!(m.bytes_in, bytes); nothing)

telemetry_exception!(m::ServerMetrics) =
    (Threads.atomic_add!(m.exceptions, 1); nothing)

@inline function _status_bucket(m::ServerMetrics, status::Int)
    100 <= status < 200 && return m.status_1xx
    200 <= status < 300 && return m.status_2xx
    300 <= status < 400 && return m.status_3xx
    400 <= status < 500 && return m.status_4xx
    500 <= status < 600 && return m.status_5xx
    return nothing
end

function telemetry_response!(m::ServerMetrics, ::UInt8, path,
                             status::Int, bytes::Int, ::Float64)
    Threads.atomic_add!(m.responses, 1)
    Threads.atomic_add!(m.bytes_out, bytes)
    bucket = _status_bucket(m, status)
    bucket === nothing || Threads.atomic_add!(bucket, 1)
    return nothing
end

"""Consistent-enough snapshot of a [`ServerMetrics`](@ref) observer."""
function metrics_snapshot(m::ServerMetrics)::NamedTuple
    return (requests   = m.requests[],
            responses  = m.responses[],
            status_1xx = m.status_1xx[],
            status_2xx = m.status_2xx[],
            status_3xx = m.status_3xx[],
            status_4xx = m.status_4xx[],
            status_5xx = m.status_5xx[],
            exceptions = m.exceptions[],
            bytes_in   = m.bytes_in[],
            bytes_out  = m.bytes_out[])
end

"""
    AccessLog(io::IO=stderr) <: AbstractTelemetry

One line per response:

    2026-09-26T07:13:25.123 "GET /hello" 200 123 0.532ms

Writes are serialized with an internal lock, so it is safe to share across
worker threads. `bytes` is the response size; `elapsed` spans from the first
request byte to the response (for streams: to the end of the body).
"""
struct AccessLog{I <: IO} <: AbstractTelemetry
    io   :: I
    lock :: ReentrantLock
end

AccessLog(io::IO=stderr) = AccessLog(io, ReentrantLock())

telemetry_capture_path(::AccessLog)::Bool = true
telemetry_active(::AccessLog)::Bool = true

function telemetry_response!(l::AccessLog, method::UInt8, path,
                             status::Int, bytes::Int, elapsed::Float64)
    line = string(now(), " \"", Methods.to_string(method), " ", path, "\" ",
                  status, " ", bytes, " ", round(elapsed * 1000; digits=3), "ms")
    lock(l.lock) do
        println(l.io, line)
    end
    return nothing
end

"""
    _TelemetryCatcher(inner, telemetry) <: AbstractCatcher

Wraps the server's catcher so intercepted exceptions are reported to the
observer; the wrapped catcher's response is untouched. Adapters hold one
instance instead of `server.catcher`.
"""
struct _TelemetryCatcher{C <: AbstractCatcher, T <: AbstractTelemetry} <: AbstractCatcher
    inner     :: C
    telemetry :: T
end

function intercept(c::_TelemetryCatcher, err::Exception, req)
    telemetry_exception!(c.telemetry)
    return intercept(c.inner, err, req)
end

export AbstractTelemetry, NullTelemetry, ServerMetrics, AccessLog,
       telemetry_request!, telemetry_response!, telemetry_read!,
       telemetry_exception!, telemetry_active, telemetry_capture_path,
       metrics_snapshot
