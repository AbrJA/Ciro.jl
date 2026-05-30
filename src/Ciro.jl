"""
    Ciro

A minimal, blazing-fast, extensible HTTP framework for Julia.
Built on Linux io_uring for maximum throughput with thread-per-core scaling.

# Quick Start
```julia
using Ciro

router = Trie()
get!(router, "/hello", ctx -> text("Hello, World!"))

server = Server(; router)
start!(server)
```

# Extension
- Custom middleware: `using Ciro.Middleware`
- Low-level io_uring: `using Ciro.Backend`
"""
module Ciro

include("Interface/Interface.jl")
include("Backend/Backend.jl")
include("Core/Core.jl")
include("Router/Router.jl")

# Middleware lives in ext/ for future extraction to CiroMiddleware.jl
include("../ext/CiroMiddleware/CiroMiddleware.jl")

using .Interfaces
using .Core
using .Router
using .Backend: IOUringBackend

# ── Public API ──────────────────────────────────────────────────────────────
# Types
export Context, Request, Response, RouteResult, Methods

# Response builders
export text, html, json, redirect, fail

# Request access
export header, hasheader, body, rawbody, content_type
export path, query, queryparams, param
export cookies, cookie, setcookie

# Routing
export Trie, register!, route
export matched, not_found, method_not_allowed
export get!, post!, put!, delete!, patch!, head!, options!, group!

# Server
export Server, start!, stop!

# Extension points (abstract types + functions)
export AbstractRouter, AbstractLogger, AbstractCatcher, AbstractBackend
export IOUringBackend
export NullLogger, DefaultCatcher
export Severity, Debug, Info, Warn, Error, Fatal
export log!, intercept, status, start_backend!, stop_backend!

end
