module Ciro

# Include submodules
include("types.jl")
include("trie.jl")
include("middleware.jl")
include("static_router.jl")
include("router.jl")
include("server.jl")

# Re-export necessary types and functions
using .Types
export Request, Response, json, text

using .Tries
using .Middlewares
export Logger

using .Routers
# Explicitly use Routers.get to shadow Base.get in this module context if intended,
# or just export it.
# To avoid the warning "both Routers and Base export get", we need to be specific.
# Since we want Senciro.get to be the router get, we should shadow it.
const get = Routers.get
const post = Routers.post
const route = Routers.route
const use = Routers.use
const GLOBAL_ROUTER = Routers.GLOBAL_ROUTER

export route, get, post, use, GLOBAL_ROUTER

using .Servers
export start_server

end # module Ciro
