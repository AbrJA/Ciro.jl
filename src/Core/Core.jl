"""
    Core

HTTP server engine built on Backend (io_uring).
Provides:
- `Server{R,L,E}` — parametric server struct (fully monomorphized)
- Zero-copy response serialization
- Thread-per-core request dispatch

trim=safe: no eval, no reflection, all concrete types.
"""
module Core

using Interfaces
using Backend
using PicoHTTPParser
using Base.Threads: @threads, nthreads

# Re-export interfaces for user convenience
using Interfaces: Request, Response, Methods, status, header, path, query,
    NullLogger, DefaultCatcher,
    text, html, json, redirect, fail,
    AbstractCatcher, intercept,
    AbstractRouter, route, register!,
    AbstractLogger, Level, Debug, Info, Warn, Error, Fatal, write

export Request, Response, Methods, status, header, path, query,
    NullLogger, DefaultCatcher,
    text, html, json, redirect, fail,
    AbstractCatcher, intercept,
    AbstractRouter, route, register!,
    AbstractLogger, Level, Debug, Info, Warn, Error, Fatal, write

include("server.jl")
include("serialize.jl")
include("worker.jl")

export Server, start!, stop!

end # module Core
