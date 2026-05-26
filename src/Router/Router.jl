"""
    Router

A fast radix-trie based router. Works with PicoHTTPParser's StringView paths.

# Usage
```julia
using Router
router = Router()
get!(router, "/", req -> text("Hello"))
get!(router, "/users/:id", req -> text("User \$(param(router, req))"))
```
"""
module Router

using Interfaces
using Interfaces: Request, Response, Methods, AbstractRouter, text, fail

export Router, get!, post!, put!, delete!, patch!, head!, options!, params, param

# ══════════════════════════════════════════════════════════════════════════════
# Trie Node
# ══════════════════════════════════════════════════════════════════════════════

mutable struct TrieNode
    children    :: Dict{String, TrieNode}
    param_child :: Union{Nothing, Tuple{Symbol, TrieNode}}
    wildcard    :: Union{Nothing, Any}
    handlers    :: Dict{UInt8, Any}
end

TrieNode() = TrieNode(Dict{String,TrieNode}(), nothing, nothing, Dict{UInt8,Any}())

# ══════════════════════════════════════════════════════════════════════════════
# Router Struct
# ══════════════════════════════════════════════════════════════════════════════

"""
    Router <: AbstractRouter

Radix-trie router with path parameters (`:name`) and wildcards (`*`).
Match priority: static > parameter > wildcard.
"""
struct Router <: AbstractRouter
    root :: TrieNode
end

Router() = Router(TrieNode())

# ══════════════════════════════════════════════════════════════════════════════
# Route Registration
# ══════════════════════════════════════════════════════════════════════════════

function Interfaces.register!(router::Router, method::UInt8, pattern::String, handler)
    segments = _split_path(pattern)
    node = router.root

    for seg in segments
        if startswith(seg, ':')
            param_name = Symbol(seg[2:end])
            if node.param_child === nothing
                node.param_child = (param_name, TrieNode())
            end
            node = node.param_child[2]
        elseif seg == "*"
            node.wildcard = handler
            return router
        else
            if !haskey(node.children, seg)
                node.children[seg] = TrieNode()
            end
            node = node.children[seg]
        end
    end

    node.handlers[method] = handler
    return router
end

# Convenience registration
Base.get!(r::Router, p::String, h)     = (register!(r, Methods.GET, p, h); r)
post!(r::Router, p::String, h)    = (register!(r, Methods.POST, p, h); r)
put!(r::Router, p::String, h)     = (register!(r, Methods.PUT, p, h); r)
delete!(r::Router, p::String, h)  = (register!(r, Methods.DELETE, p, h); r)
patch!(r::Router, p::String, h)   = (register!(r, Methods.PATCH, p, h); r)
head!(r::Router, p::String, h)    = (register!(r, Methods.HEAD, p, h); r)
options!(r::Router, p::String, h) = (register!(r, Methods.OPTIONS, p, h); r)

# ══════════════════════════════════════════════════════════════════════════════
# Route Dispatch
# ══════════════════════════════════════════════════════════════════════════════

"""
    route(router::Router, method::UInt8, path::AbstractString) -> Union{Nothing, handler}

Match the request to a handler. If route has params, returns a closure
that injects params into a thread-local storage before calling the handler.
"""
function Interfaces.route(router::Router, method::UInt8, path::AbstractString)
    segments = _split_path_view(path)
    params = Pair{Symbol,String}[]

    handler = _match(router.root, segments, 1, method, params)
    handler === nothing && return nothing

    if isempty(params)
        return handler
    else
        # Capture params in a closure — the handler can retrieve them via route_params()
        captured = copy(params)
        return function(req)
            # Store params in task-local storage for zero-allocation access
            task_local_storage(:_ciro_params, captured)
            return handler(req)
        end
    end
end

"""
    params() -> Vector{Pair{Symbol,String}}

Get route parameters for the current request (from task-local storage).
"""
function params()::Vector{Pair{Symbol,String}}
    get(task_local_storage(), :_ciro_params, Pair{Symbol,String}[])
end

"""
    param(name::Symbol, default::String="") -> String

Get a single route parameter by name.
"""
function param(name::Symbol, default::String="")::String
    params = params()
    for (k, v) in params
        k === name && return v
    end
    return default
end

export params, param

# ══════════════════════════════════════════════════════════════════════════════
# Internal Matching
# ══════════════════════════════════════════════════════════════════════════════

function _match(node::TrieNode, segments::Vector{String}, idx::Int,
                method::UInt8, params::Vector{Pair{Symbol,String}})
    # Base case: all segments consumed
    if idx > length(segments)
        return get(node.handlers, method, nothing)
    end

    seg = segments[idx]

    # Priority 1: exact static match
    if haskey(node.children, seg)
        result = _match(node.children[seg], segments, idx + 1, method, params)
        result !== nothing && return result
    end

    # Priority 2: parameter
    if node.param_child !== nothing
        (pname, child) = node.param_child
        push!(params, pname => seg)
        result = _match(child, segments, idx + 1, method, params)
        result !== nothing && return result
        pop!(params)  # backtrack
    end

    # Priority 3: wildcard
    if node.wildcard !== nothing
        return node.wildcard
    end

    return nothing
end

# ── Path Splitting ──────────────────────────────────────────────────────────

function _split_path(path::String)::Vector{String}
    segments = String[]
    n = sizeof(path)
    i = 1
    while i <= n
        # Skip slashes
        while i <= n && @inbounds(codeunit(path, i)) == UInt8('/')
            i += 1
        end
        i > n && break
        # Find end of segment
        j = i
        while j <= n && @inbounds(codeunit(path, j)) != UInt8('/')
            j += 1
        end
        push!(segments, path[i:j-1])
        i = j
    end
    return segments
end

function _split_path_view(path::AbstractString)::Vector{String}
    _split_path(String(path))
end

end # module Router
