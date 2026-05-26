module Router

using ..Interfaces
using ..Interfaces: Request, Response, Methods, AbstractRouter, text, fail

export Trie, get!, post!, put!, delete!, patch!, head!, options!, params, param

# Extend Base functions to avoid ambiguity with `using`
import Base: get!, put!, delete!

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

struct Trie <: AbstractRouter
    root::TrieNode
end

Trie() = Trie(TrieNode())

# ══════════════════════════════════════════════════════════════════════════════
# Route Registration
# ══════════════════════════════════════════════════════════════════════════════

function Interfaces.register!(trie::Trie, method::UInt8, pattern::String, handler)
    segments = _split_path(pattern)
    node = trie.root

    for seg in segments
        if startswith(seg, ':')
            param_name = Symbol(seg[2:end])
            if node.param_child === nothing
                node.param_child = (param_name, TrieNode())
            end
            node = node.param_child[2]
        elseif seg == "*"
            node.wildcard = handler
            return trie
        else
            if !haskey(node.children, seg)
                node.children[seg] = TrieNode()
            end
            node = node.children[seg]
        end
    end

    node.handlers[method] = handler
    return trie
end

# Convenience registration (extending Base where names overlap)
Base.get!(r::Trie, p::String, h)     = (register!(r, Methods.GET, p, h); r)
post!(r::Trie, p::String, h)    = (register!(r, Methods.POST, p, h); r)
Base.put!(r::Trie, p::String, h)     = (register!(r, Methods.PUT, p, h); r)
Base.delete!(r::Trie, p::String, h)  = (register!(r, Methods.DELETE, p, h); r)
patch!(r::Trie, p::String, h)   = (register!(r, Methods.PATCH, p, h); r)
head!(r::Trie, p::String, h)    = (register!(r, Methods.HEAD, p, h); r)
options!(r::Trie, p::String, h) = (register!(r, Methods.OPTIONS, p, h); r)

# ══════════════════════════════════════════════════════════════════════════════
# Route Dispatch
# ══════════════════════════════════════════════════════════════════════════════

function Interfaces.route(trie::Trie, method::UInt8, path::AbstractString)
    segments = _split_path_view(path)
    params = Pair{Symbol,String}[]

    handler = _match(trie.root, segments, 1, method, params)
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

function params()::Vector{Pair{Symbol,String}}
    get(task_local_storage(), :_ciro_params, Pair{Symbol,String}[])
end

function param(name::Symbol, default::String="")::String
    ps = params()
    for (k, v) in ps
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
