module Ciro

# Core types
include("types.jl")

# Middleware library
include("middleware.jl")

# Static router (primary dispatch mechanism)
include("static_router.jl")

# Server (io_uring backend)
include("server.jl")

# Re-export public API
using .Types
export Request, Response, text, json

using .Middlewares
export Logger

using .StaticRouter
export @routes, dispatch, AbstractApp

using .Servers
export start_server, stop_server

end # module Ciro
