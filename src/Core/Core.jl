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
using ..Interface: Request, RequestContext, Response, Context, RouteResult, matched, not_found, method_not_allowed, status, hasheader, log!, execute!, freeze!
import ..Interface: stop!
using ..Backend
using ..Runtime: dispatch
using ..HTTP
import ..HTTP: io_read, io_write, io_on_write, io_shutdown, io_close, io_release, io_dispatch
using ..HTTP: serialize_response!, _http_date
import PicoHTTPParser
using PicoHTTPParser: HeaderBuffer, parse_request_head!, head_length, request_method,
                      request_target, minor_version, header_name, header_value,
                      content_length, HTTPParseError,
                      ChunkedDecoder, decode_chunked!
using Base.Threads: @threads, nthreads

include("server.jl")
include("worker.jl")

export Server, start!, stop!

end # module Core
