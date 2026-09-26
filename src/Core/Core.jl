"""
    Core

HTTP server engine. Provides:
- `Server{R,L,C}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch
- Graceful shutdown with request draining
"""
module Core

using ..Interface
using ..Interface: Request, RequestContext, Response, Context, RouteResult, matched, not_found, method_not_allowed, log!, execute!, freeze!
import ..Interface: stop!
using ..Backend
using ..Runtime: dispatch
using ..HTTP
import ..HTTP: io_config, io_running, io_read, io_acquire_buffer, io_write,
               io_on_write, io_shutdown, io_close, io_release, io_dispatch
using ..HTTP: HTTPConfig, HTTPConn, http_reset!, http_on_read, http_on_write,
              http_retire, http_finalize, http_expired,
              _wants_close, serialize_response!, _http_date
import PicoHTTPParser
using Base.Threads: @threads, nthreads

include("server.jl")
include("worker.jl")

export Server, start!, stop!

end # module Core
