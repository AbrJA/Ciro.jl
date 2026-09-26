module Router

using ..Interface
using ..Interface: Request, Response, Methods, AbstractRouter, RouteResult,
                   Endpoint, matched, not_found, method_not_allowed, text, fail

export Trie, get!, post!, put!, delete!, patch!, head!, options!, group!, freeze!

import Base: get!, put!, delete!

# ══════════════════════════════════════════════════════════════════════════════
# Parameter Spec — parsed at registration time, validated at match time
# ══════════════════════════════════════════════════════════════════════════════

struct ParamSpec
    name :: Symbol
    type :: Symbol  # :String, :Int, :Float64, :UUID
end

@inline function _parse_param(seg::String)::ParamSpec
    raw = seg[2:end]
    parts = split(raw, "::", limit=2)
    name = Symbol(parts[1])
    type = length(parts) == 2 ? Symbol(parts[2]) : :String
    return ParamSpec(name, type)
end

@inline function _validate_param(value::String, spec::ParamSpec)::Bool
    spec.type === :String && return true
    spec.type === :Int && return _is_integer(value)
    spec.type === :Float64 && return _is_number(value)
    spec.type === :UUID && return ncodeunits(value) == 36
    return true
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

@inline function _is_number(s::String)::Bool
    isempty(s) && return false
    dot_seen = false
    start = @inbounds(codeunit(s, 1)) == UInt8('-') ? 2 : 1
    start > ncodeunits(s) && return false
    for i in start:ncodeunits(s)
        b = @inbounds codeunit(s, i)
        if b == UInt8('.')
            dot_seen && return false
            dot_seen = true
        elseif b < UInt8('0') || b > UInt8('9')
            return false
        end
    end
    return true
end

# ══════════════════════════════════════════════════════════════════════════════
# Trie Node
# ══════════════════════════════════════════════════════════════════════════════

mutable struct TrieNode
    children    :: Dict{String, TrieNode}
    param_child :: Union{Nothing, Tuple{ParamSpec, TrieNode}}
    wildcard    :: Dict{UInt8, Any}
    handlers    :: Dict{UInt8, Any}  # method -> handler
end

TrieNode() = TrieNode(Dict{String,TrieNode}(), nothing, Dict{UInt8,Any}(), Dict{UInt8,Any}())

# ══════════════════════════════════════════════════════════════════════════════
# Router Struct
# ══════════════════════════════════════════════════════════════════════════════

mutable struct Trie <: AbstractRouter
    root :: TrieNode
    frozen :: Bool
end

Trie() = Trie(TrieNode(), false)

# ══════════════════════════════════════════════════════════════════════════════
# Route Registration
# ══════════════════════════════════════════════════════════════════════════════

function Interface.register!(trie::Trie, method::UInt8, pattern::String, handler)
    trie.frozen && throw(ArgumentError("cannot register routes on a frozen router"))
    endpoint = handler isa Endpoint ? handler : Endpoint(handler)
    segments = _split_path(pattern)
    node = trie.root

    for seg in segments
        if startswith(seg, ':')
            spec = _parse_param(seg)
            if node.param_child === nothing
                node.param_child = (spec, TrieNode())
            end
            node = (node.param_child::Tuple{ParamSpec, TrieNode})[2]
        elseif seg == "*"
            node.wildcard[method] = endpoint
            return trie
        else
            if !haskey(node.children, seg)
                node.children[seg] = TrieNode()
            end
            node = node.children[seg]
        end
    end

    node.handlers[method] = endpoint

    # Auto-generate HEAD from GET (RFC 9110 §9.3.2): the GET handler runs, but
    # the response is sent without a body and with the GET entity's
    # Content-Length, which is what HEAD must report.
    if method == Methods.GET && !haskey(node.handlers, Methods.HEAD)
        node.handlers[Methods.HEAD] = Endpoint(function(ctx)
            resp = endpoint(ctx)
            headers = copy(resp.headers)
            _set_content_length!(headers, length(resp.body))
            return Response(resp.status, headers, UInt8[])
        end; metadata=endpoint.metadata)
    end

    return trie
end

function _set_content_length!(headers::Vector{Pair{String,String}}, n::Int)
    for i in eachindex(headers)
        _hdr_key_eq_ci(headers[i].first, "Content-Length") || continue
        headers[i] = "Content-Length" => string(n)
        return
    end
    push!(headers, "Content-Length" => string(n))
    return
end

"""Zero-allocation case-insensitive ASCII comparison."""
@inline function _hdr_key_eq_ci(a::AbstractString, b::String)::Bool
    ncodeunits(a) != ncodeunits(b) && return false
    for i in 1:ncodeunits(b)
        ca = @inbounds codeunit(a, i)
        cb = @inbounds codeunit(b, i)
        ca_lower = (UInt8('A') <= ca <= UInt8('Z')) ? (ca | 0x20) : ca
        cb_lower = (UInt8('A') <= cb <= UInt8('Z')) ? (cb | 0x20) : cb
        ca_lower != cb_lower && return false
    end
    return true
end

function Interface.freeze!(trie::Trie)
    trie.frozen = true
    return trie
end

# ── Convenience registration ────────────────────────────────────────────────

Base.get!(r::Trie, p::String, h)     = (register!(r, Methods.GET, p, h); r)
post!(r::Trie, p::String, h)    = (register!(r, Methods.POST, p, h); r)
Base.put!(r::Trie, p::String, h)     = (register!(r, Methods.PUT, p, h); r)
Base.delete!(r::Trie, p::String, h)  = (register!(r, Methods.DELETE, p, h); r)
patch!(r::Trie, p::String, h)   = (register!(r, Methods.PATCH, p, h); r)
head!(r::Trie, p::String, h)    = (register!(r, Methods.HEAD, p, h); r)
options!(r::Trie, p::String, h) = (register!(r, Methods.OPTIONS, p, h); r)

# ══════════════════════════════════════════════════════════════════════════════
# Route Groups — prefix-based organization
# ══════════════════════════════════════════════════════════════════════════════

"""
    group!(router, prefix) do r
        get!(r, "/items", handler)
        post!(r, "/items", handler)
    end

Register routes under a common prefix. The block receives a scoped
registration proxy.
"""
function group!(f::Function, trie::Trie, prefix::String)
    proxy = _GroupProxy(trie, _normalize_prefix(prefix))
    f(proxy)
    return trie
end

struct _GroupProxy
    trie   :: Trie
    prefix :: String
end

Base.get!(g::_GroupProxy, p::String, h)     = (register!(g.trie, Methods.GET, g.prefix * p, h); g.trie)
post!(g::_GroupProxy, p::String, h)    = (register!(g.trie, Methods.POST, g.prefix * p, h); g.trie)
Base.put!(g::_GroupProxy, p::String, h)     = (register!(g.trie, Methods.PUT, g.prefix * p, h); g.trie)
Base.delete!(g::_GroupProxy, p::String, h)  = (register!(g.trie, Methods.DELETE, g.prefix * p, h); g.trie)
patch!(g::_GroupProxy, p::String, h)   = (register!(g.trie, Methods.PATCH, g.prefix * p, h); g.trie)
head!(g::_GroupProxy, p::String, h)    = (register!(g.trie, Methods.HEAD, g.prefix * p, h); g.trie)
options!(g::_GroupProxy, p::String, h) = (register!(g.trie, Methods.OPTIONS, g.prefix * p, h); g.trie)

# Nested groups
group!(f::Function, g::_GroupProxy, prefix::String) = group!(f, g.trie, g.prefix * _normalize_prefix(prefix))

function _normalize_prefix(prefix::String)::String
    # Ensure prefix starts with / and doesn't end with /
    p = startswith(prefix, '/') ? prefix : "/" * prefix
    endswith(p, '/') ? p[1:end-1] : p
end

export group!

# ══════════════════════════════════════════════════════════════════════════════
# Route Dispatch — returns RouteResult (type-stable)
# ══════════════════════════════════════════════════════════════════════════════

function Interface.route(trie::Trie, method::UInt8, path::AbstractString)::RouteResult
    len = ncodeunits(path)
    captured = Pair{Symbol,String}[]

    handler = _match_path(trie.root, path, 1, len, method, captured)

    if handler !== nothing
        return RouteResult(handler, captured)
    end

    # No handler found — check if path exists with other methods (→ 405)
    allowed_mask = _find_allowed_path(trie.root, path, 1, len)
    if allowed_mask != 0x00
        return RouteResult(allowed_mask)
    end

    # No path match at all → 404
    return RouteResult()
end

# ══════════════════════════════════════════════════════════════════════════════
# Internal: Zero-alloc Trie Matching (inline segment iteration)
# ══════════════════════════════════════════════════════════════════════════════

function _match_path(node::TrieNode, path::AbstractString, pos::Int, len::Int,
                     method::UInt8, captured::Vector{Pair{Symbol,String}})
    # Skip leading slashes
    while pos <= len && @inbounds(codeunit(path, pos)) == UInt8('/')
        pos += 1
    end

    # End of path — check handlers at this node
    if pos > len
        return get(node.handlers, method, nothing)
    end

    # Extract current segment boundaries (zero-alloc SubString)
    seg_start = pos
    while pos <= len && @inbounds(codeunit(path, pos)) != UInt8('/')
        pos += 1
    end
    seg = SubString(path, seg_start, pos - 1)

    # Priority 1: exact static match (Dict lookup with SubString works via hash/isequal)
    child = get(node.children, seg, nothing)
    if child !== nothing
        result = _match_path(child, path, pos, len, method, captured)
        result !== nothing && return result
    end

    # Priority 2: typed parameter
    if node.param_child !== nothing
        (spec, pchild) = node.param_child
        seg_str = String(seg)
        if _validate_param(seg_str, spec)
            push!(captured, spec.name => seg_str)
            result = _match_path(pchild, path, pos, len, method, captured)
            result !== nothing && return result
            pop!(captured)
        end
    end

    # Priority 3: wildcard
    wildcard_handler = get(node.wildcard, method, nothing)
    if wildcard_handler !== nothing
        return wildcard_handler
    end

    return nothing
end

"""Build a bitmask of all methods registered for a path (for 405 Allow header)."""
function _find_allowed_path(node::TrieNode, path::AbstractString, pos::Int, len::Int)::UInt8
    # Skip leading slashes
    while pos <= len && @inbounds(codeunit(path, pos)) == UInt8('/')
        pos += 1
    end

    if pos > len
        mask = UInt8(0)
        for m in keys(node.handlers)
            mask |= Methods.bitmask(m)
        end
        return mask
    end

    seg_start = pos
    while pos <= len && @inbounds(codeunit(path, pos)) != UInt8('/')
        pos += 1
    end
    seg = SubString(path, seg_start, pos - 1)

    child = get(node.children, seg, nothing)
    if child !== nothing
        result = _find_allowed_path(child, path, pos, len)
        result != 0x00 && return result
    end

    if node.param_child !== nothing
        (spec, pchild) = node.param_child
        if _validate_param(String(seg), spec)
            result = _find_allowed_path(pchild, path, pos, len)
            result != 0x00 && return result
        end
    end

    mask = UInt8(0)
    for wildcard_method in keys(node.wildcard)
        mask |= Methods.bitmask(wildcard_method)
    end
    return mask
end

# ══════════════════════════════════════════════════════════════════════════════
# Path Splitting (used only at registration time, not in hot path)
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

end # module Router
