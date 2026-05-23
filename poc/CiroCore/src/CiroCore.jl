"""
    CiroCore

HTTP server engine built on CiroBackend (io_uring).
Provides:
- `CiroServer{R,L,E}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch

trim=safe: no eval, no reflection, all concrete types.
"""
module CiroCore

using CiroInterfaces
using CiroBackend
using PicoHTTPParser
using Base.Threads: @threads, nthreads

# Re-export interfaces for user convenience
using CiroInterfaces: AbstractRouter, AbstractLogger, AbstractErrorHandler,
    Request, Response, Methods, NullLogger, DefaultErrorHandler,
    text, html, json_response, redirect, error_response,
    status_line, hasheader, getheader, req_header,
    route, add_route!, log_event, handle_error, clean_path, query_string,
    LogLevel, DEBUG, INFO, WARN, ERROR_LEVEL, FATAL

export AbstractRouter, AbstractLogger, AbstractErrorHandler,
    Request, Response, Methods, NullLogger, DefaultErrorHandler,
    text, html, json_response, redirect, error_response,
    status_line, hasheader, getheader, req_header,
    route, add_route!, log_event, handle_error, clean_path, query_string,
    LogLevel, DEBUG, INFO, WARN, ERROR_LEVEL, FATAL

include("server.jl")
include("serialize.jl")
include("worker.jl")

export CiroServer, start!, stop!

end # module CiroCore
