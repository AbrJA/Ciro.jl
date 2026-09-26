"""
    Core

HTTP server engine. Provides:
- `Server{R,L,C,E,T}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch
- Graceful shutdown with request draining
"""
module Core

using ..Interface
using ..Interface: Request, RequestContext, Response, Context, RouteResult, matched, not_found, method_not_allowed, log!, execute!, freeze!
import ..Interface: stop!, _TelemetryCatcher
using ..Backend
using ..Runtime: dispatch, dispatch_async
using ..HTTP
import ..HTTP: io_config, io_running, io_read, io_acquire_buffer, io_write,
               io_on_write, io_shutdown, io_close, io_release, io_dispatch,
               io_isasync, io_dispatch_async, io_telemetry, io_route
using ..HTTP: HTTPConfig, HTTPConn, http_reset!, http_on_read, http_on_write,
              http_retire, http_finalize, http_expired,
              http_deliver_response, http_stream_begin, http_stream_chunk,
              http_stream_end, _wants_close, serialize_response!, _http_date
import PicoHTTPParser
using Sockets
using Base.Threads: @threads, nthreads

include("server.jl")
include("worker.jl")
include("sockets.jl")

export Server, start!, stop!

end # module Core
