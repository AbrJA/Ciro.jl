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
# HTTP method convenience functions
const get = Routers.get
const post = Routers.post
const put = Routers.put
const delete = Routers.delete
const patch = Routers.patch
const options = Routers.options
const head = Routers.head
const route = Routers.route
const use = Routers.use
const GLOBAL_ROUTER = Routers.GLOBAL_ROUTER

export route, get, post, put, delete, patch, options, head, use, GLOBAL_ROUTER

using .Servers
export start_server, stop_server

end # module Ciro
