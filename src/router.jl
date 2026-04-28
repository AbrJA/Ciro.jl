module Routers

using ..Types
using ..Tries

export Router, GLOBAL_ROUTER, route, get, post, put, delete, patch, options, head, use

struct Router
    trie::RouterTrie
    middlewares::Vector{Function}
end

const GLOBAL_ROUTER = Router(RouterTrie(), Function[])

function use(middleware::Function)
    push!(GLOBAL_ROUTER.middlewares, middleware)
end

function route(method::String, path::String, handler::Function)
    Tries.insert!(GLOBAL_ROUTER.trie, method, path, handler)
end

function get(handler::Function, path::String)
    route("GET", path, handler)
end

function post(handler::Function, path::String)
    route("POST", path, handler)
end

function put(handler::Function, path::String)
    route("PUT", path, handler)
end

function delete(handler::Function, path::String)
    route("DELETE", path, handler)
end

function patch(handler::Function, path::String)
    route("PATCH", path, handler)
end

function options(handler::Function, path::String)
    route("OPTIONS", path, handler)
end

function head(handler::Function, path::String)
    route("HEAD", path, handler)
end

end
