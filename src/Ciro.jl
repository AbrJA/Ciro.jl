module Ciro

# Core types (Request, Response, builders)
include("types.jl")

# Middleware library (Logger, CORS)
include("middleware.jl")

# Static router (compile-time trie dispatch)
include("static_router.jl")

# Server (io_uring backend)
include("server.jl")

# Re-export public API
using .Types
export Request, Response, text, json, html, Methods

using .Middlewares
export Logger, CORS, cors

using .StaticRouter
export @routes, dispatch, AbstractApp

using .Servers
export start_server, stop_server

end
