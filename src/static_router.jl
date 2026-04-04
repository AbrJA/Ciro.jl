module StaticRouter

using StringViews
using ..Types
using ..Types: Methods

export @routes, dispatch, AbstractApp

abstract type AbstractApp end

function dispatch end

# --- Fast Path Utilities ---

@inline function find_next_slash(path::AbstractString, start_idx::Int)::Int
    len = ncodeunits(path)
    for i in start_idx:len
        @inbounds codeunit(path, i) == UInt8('/') && return i
    end
    return 0
end

@inline function skip_slashes(path::AbstractString, idx::Int)::Int
    len = ncodeunits(path)
    while idx <= len && @inbounds codeunit(path, idx) == UInt8('/')
        idx += 1
    end
    return idx
end

@inline function segment_eq(path::AbstractString, start::Int, stop::Int, seg::String)::Bool
    n = stop - start
    n != sizeof(seg) && return false
    for i in 0:n-1
        @inbounds codeunit(path, start + i) != codeunit(seg, 1 + i) && return false
    end
    return true
end

# --- Route Parsing ---

function parse_route_pattern(pattern::String)
    raw_segments = split(pattern, "/", keepempty=false)
    segments = []
    for seg in raw_segments
        if startswith(seg, ":")
            push!(segments, (:variable, Symbol(seg[2:end])))
        elseif seg == "*"
            push!(segments, (:wildcard, :_wildcard))
        else
            push!(segments, (:static, String(seg)))
        end
    end
    return segments
end

# --- Trie Node for Compile-Time Route Organization ---

mutable struct TrieNode
    static_children::Dict{String, TrieNode}
    param_child::Union{Nothing, Tuple{Symbol, TrieNode}}
    wildcard_child::Union{Nothing, Tuple{Symbol, Any}}  # (name, handler_func)
    handler::Union{Nothing, Any}  # just the func (Expr/Symbol)
end

TrieNode() = TrieNode(Dict{String,TrieNode}(), nothing, nothing, nothing)

function insert_route!(root::TrieNode, segments, func)
    node = root
    for (seg_type, val) in segments
        if seg_type == :static
            if !haskey(node.static_children, val)
                node.static_children[val] = TrieNode()
            end
            node = node.static_children[val]
        elseif seg_type == :variable
            if node.param_child === nothing
                node.param_child = (val, TrieNode())
            end
            node = node.param_child[2]
        elseif seg_type == :wildcard
            node.wildcard_child = (val, func)
            return
        end
    end
    node.handler = func
end

# --- Code Generation from Trie ---
# `accumulated_params` tracks the param symbols captured during trie walk

function generate_trie_dispatch(node::TrieNode, depth::Int, middlewares, accumulated_params::Vector{Symbol})
    stmts = Expr[]

    # If this node has a handler — match when path is fully consumed
    if node.handler !== nothing
        func = node.handler
        handler_call = :($(esc(func))(req, $(accumulated_params...)))
        action = wrap_with_middlewares(handler_call, middlewares)
        push!(stmts, quote
            if _idx > _len
                $action
            end
        end)
    end

    # Static children
    for (seg_str, child) in node.static_children
        child_code = generate_trie_dispatch(child, depth + 1, middlewares, accumulated_params)
        push!(stmts, quote
            if _idx <= _len
                _end = StaticRouter.find_next_slash(req.path, _idx)
                if _end == 0
                    _end = _len + 1
                end
                if StaticRouter.segment_eq(req.path, _idx, _end, $seg_str)
                    _idx_save = _idx
                    _idx = StaticRouter.skip_slashes(req.path, _end)
                    $child_code
                    _idx = _idx_save
                end
            end
        end)
    end

    # Param child — capture segment as SubString
    if node.param_child !== nothing
        (param_sym, child) = node.param_child
        new_params = vcat(accumulated_params, [param_sym])
        child_code = generate_trie_dispatch(child, depth + 1, middlewares, new_params)
        push!(stmts, quote
            if _idx <= _len
                _end = StaticRouter.find_next_slash(req.path, _idx)
                if _end == 0
                    _end = _len + 1
                end
                if _idx < _end
                    $(param_sym) = view(req.path, _idx:_end-1)
                    _idx_save = _idx
                    _idx = StaticRouter.skip_slashes(req.path, _end)
                    $child_code
                    _idx = _idx_save
                end
            end
        end)
    end

    # Wildcard — match rest of path
    if node.wildcard_child !== nothing
        (wsym, func) = node.wildcard_child
        handler_call = :($(esc(func))(req, $(accumulated_params...)))
        action = wrap_with_middlewares(handler_call, middlewares)
        push!(stmts, quote
            if _idx <= _len
                $action
            end
        end)
    end

    return Expr(:block, stmts...)
end

function wrap_with_middlewares(handler_call, middlewares)
    if isempty(middlewares)
        return quote
            local _response = try
                local _r = $handler_call
                isa(_r, Response) ? _r : text(string(_r))
            catch e
                @error "Handler error" exception=(e, catch_backtrace())
                Response(500, "Internal Server Error")
            end
            return _response
        end
    end

    # Build from inside out: innermost = handler
    inner = handler_call
    for mw in reverse(middlewares)
        prev = inner
        inner = quote
            $(esc(mw))(req, function(_mw_req)
                local _r = $prev
                isa(_r, Response) ? _r : text(string(_r))
            end)
        end
    end

    return quote
        local _response = try
            local _r = $inner
            isa(_r, Response) ? _r : text(string(_r))
        catch e
            @error "Handler error" exception=(e, catch_backtrace())
            Response(500, "Internal Server Error")
        end
        return _response
    end
end

# --- Main Macro ---

macro routes(app_type::Symbol, block)
    routes_by_method = Dict{String, Vector{Tuple}}()
    middlewares = []

    if block.head == :block
        for line in block.args
            line isa Expr || continue

            if line.head == :call && line.args[1] == :middleware
                push!(middlewares, line.args[2])
            elseif line.head == :call && line.args[1] == :(=>)
                if length(line.args[2].args) == 2
                    (method, path) = line.args[2].args
                    func = line.args[3]
                    if !haskey(routes_by_method, method)
                        routes_by_method[method] = Vector{Tuple}()
                    end
                    push!(routes_by_method[method], (path, func))
                end
            end
        end
    end

    # Build a trie per HTTP method for O(depth) lookup
    method_blocks = Expr[]

    for (method, routes) in routes_by_method
        root = TrieNode()

        for (path, func) in routes
            segments = parse_route_pattern(path)
            insert_route!(root, segments, func)
        end

        trie_code = generate_trie_dispatch(root, 0, middlewares, Symbol[])

        # Use Methods enum for fast method dispatch
        method_tag = if method == "GET"
            :(Methods.GET)
        elseif method == "POST"
            :(Methods.POST)
        elseif method == "PUT"
            :(Methods.PUT)
        elseif method == "DELETE"
            :(Methods.DELETE)
        elseif method == "PATCH"
            :(Methods.PATCH)
        elseif method == "HEAD"
            :(Methods.HEAD)
        elseif method == "OPTIONS"
            :(Methods.OPTIONS)
        else
            :(Methods.UNKNOWN)
        end

        push!(method_blocks, quote
            if _method == $method_tag
                _idx = 1
                _len = ncodeunits(req.path)
                _idx = StaticRouter.skip_slashes(req.path, _idx)
                $trie_code
            end
        end)
    end

    dispatch_body = Expr(:block, method_blocks..., :(return Response(404, "Not Found")))

    quote
        struct $(esc(app_type)) <: StaticRouter.AbstractApp end

        function StaticRouter.dispatch(::$(esc(app_type)), req::Request)
            _method = Methods.from_string(req.method)
            $dispatch_body
        end
    end
end

end
