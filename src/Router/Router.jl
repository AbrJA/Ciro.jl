module Router

using ..Interfaces
using ..Interfaces: Request, Response, Methods, AbstractRouter, MethodNotAllowed, text, fail

export Trie, get!, post!, put!, delete!, patch!, head!, options!, params, param

# Extend Base functions to avoid ambiguity with `using`
import Base: get!, put!, delete!

# ══════════════════════════════════════════════════════════════════════════════
# Parameter Types
# ══════════════════════════════════════════════════════════════════════════════

"""Parameter constraint parsed from route pattern (e.g. `:id::Int`)."""
struct ParamSpec
    name :: Symbol
    type :: Symbol  # :String, :Int, :UUID
end

"""Parse a parameter segment like `:id` or `:id::Int`."""
function _parse_param(seg::String)::ParamSpec
    raw = seg[2:end]  # strip leading ':'
    parts = split(raw, "::", limit=2)
    name = Symbol(parts[1])
    type = length(parts) == 2 ? Symbol(parts[2]) : :String
    return ParamSpec(name, type)
end

"""Validate a path segment against a param type constraint. Returns `nothing` on failure."""
@inline function _validate_param(value::String, spec::ParamSpec)::Bool
    spec.type === :String && return true
    spec.type === :Int && return _is_integer(value)
    spec.type === :UUID && return _is_uuid(value)
    return true  # unknown types pass through
end

@inline function _is_integer(s::String)::Bool
    isempty(s) && return false
    start = @inbounds(codeunit(s, 1)) == UInt8('-') ? 2 : 1
    start > ncodeunits(s) && return false
    for i in start:ncodeunits(s)
        b = @inbounds codeunit(s, i)
        (b < UInt8('0') || b > UInt8('9')) && return false
    end
    return true
end

@inline function _is_uuid(s::String)::Bool
    ncodeunits(s) == 36
end

# ══════════════════════════════════════════════════════════════════════════════
# Trie Node
# ══════════════════════════════════════════════════════════════════════════════

mutable struct TrieNode
    children    :: Dict{String, TrieNode}
    param_child :: Union{Nothing, Tuple{ParamSpec, TrieNode}}
    wildcard    :: Union{Nothing, Any}
    handlers    :: Dict{UInt8, Any}
end

TrieNode() = TrieNode(Dict{String,TrieNode}(), nothing, nothing, Dict{UInt8,Any}())

# ══════════════════════════════════════════════════════════════════════════════
# Router Struct
# ══════════════════════════════════════════════════════════════════════════════

struct Trie <: AbstractRouter
    root :: TrieNode
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
            spec = _parse_param(seg)
            if node.param_child === nothing
                node.param_child = (spec, TrieNode())
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

"""
    route(trie::Trie, method::UInt8, path) -> handler | MethodNotAllowed | nothing

Returns:
- A callable handler on match
- `MethodNotAllowed(allowed_methods)` if path exists but method doesn't (→ 405)
- `nothing` if no path matches (→ 404)
"""
function Interfaces.route(trie::Trie, method::UInt8, path::AbstractString)
    segments = _split_path_view(path)
    captured = Pair{Symbol,String}[]

    result = _match(trie.root, segments, 1, method, captured)

    # Handler found
    if result !== nothing
        if isempty(captured)
            return result
        else
            params_copy = copy(captured)
            return function(req)
                task_local_storage(:_ciro_params, params_copy)
                return result(req)
            end
        end
    end

    # Path matched but method didn't? Check for 405
    allowed = _find_allowed_methods(trie.root, segments, 1)
    if !isempty(allowed)
        return MethodNotAllowed(allowed)
    end

    return nothing
end

# ══════════════════════════════════════════════════════════════════════════════
# Parameter Access (task-local, zero-allocation on repeat access)
# ══════════════════════════════════════════════════════════════════════════════

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

"""Get a typed parameter. Returns `nothing` if parsing fails."""
function param(::Type{T}, name::Symbol)::Union{T, Nothing} where T
    v = param(name)
    isempty(v) && return nothing
    try
        return parse(T, v)
    catch
        return nothing
    end
end

export params, param

# ══════════════════════════════════════════════════════════════════════════════
# Internal Matching
# ══════════════════════════════════════════════════════════════════════════════

function _match(node::TrieNode, segments::Vector{String}, idx::Int,
                method::UInt8, captured::Vector{Pair{Symbol,String}})
    # Base case: all segments consumed
    if idx > length(segments)
        return get(node.handlers, method, nothing)
    end

    seg = segments[idx]

    # Priority 1: exact static match
    if haskey(node.children, seg)
        result = _match(node.children[seg], segments, idx + 1, method, captured)
        result !== nothing && return result
    end

    # Priority 2: typed parameter
    if node.param_child !== nothing
        (spec, child) = node.param_child
        if _validate_param(seg, spec)
            push!(captured, spec.name => seg)
            result = _match(child, segments, idx + 1, method, captured)
            result !== nothing && return result
            pop!(captured)  # backtrack
        end
    end

    # Priority 3: wildcard (catches all remaining segments)
    if node.wildcard !== nothing
        return node.wildcard
    end

    return nothing
end

"""Find all methods registered for a given path (for 405 Allow header)."""
function _find_allowed_methods(node::TrieNode, segments::Vector{String}, idx::Int)::Vector{UInt8}
    if idx > length(segments)
        return collect(keys(node.handlers))
    end

    seg = segments[idx]

    # Static match
    if haskey(node.children, seg)
        result = _find_allowed_methods(node.children[seg], segments, idx + 1)
        !isempty(result) && return result
    end

    # Parameter match
    if node.param_child !== nothing
        (spec, child) = node.param_child
        if _validate_param(seg, spec)
            result = _find_allowed_methods(child, segments, idx + 1)
            !isempty(result) && return result
        end
    end

    return UInt8[]
end

# ══════════════════════════════════════════════════════════════════════════════
# Path Splitting
# ══════════════════════════════════════════════════════════════════════════════

function _split_path(path::String)::Vector{String}
    segments = String[]
    n = sizeof(path)
    i = 1
    while i <= n
        while i <= n && @inbounds(codeunit(path, i)) == UInt8('/')
            i += 1
        end
        i > n && break
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
