module Router

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
    wildcard_child::Union{Nothing, Tuple{Symbol, Any}}
    handler::Union{Nothing, Any}
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

function generate_trie_dispatch(node::TrieNode, depth::Int, middlewares, accumulated_params::Vector{Symbol})
    stmts = Expr[]

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
                _end = Router.find_next_slash(req.path, _idx)
                if _end == 0 || _end > _len
                    _end = _len + 1
                end
                if Router.segment_eq(req.path, _idx, _end, $seg_str)
                    _idx_save = _idx
                    _idx = Router.skip_slashes(req.path, _end)
                    _idx > _len && (_idx = _len + 1)
                    $child_code
                    _idx = _idx_save
                end
            end
        end)
    end

    # Param child
    if node.param_child !== nothing
        (param_sym, child) = node.param_child
        new_params = vcat(accumulated_params, [param_sym])
        child_code = generate_trie_dispatch(child, depth + 1, middlewares, new_params)
        push!(stmts, quote
            if _idx <= _len
                _end = Router.find_next_slash(req.path, _idx)
                if _end == 0 || _end > _len
                    _end = _len + 1
                end
                if _idx < _end
                    $(param_sym) = view(req.path, _idx:_end-1)
                    _idx_save = _idx
                    _idx = Router.skip_slashes(req.path, _end)
                    _idx > _len && (_idx = _len + 1)
                    $child_code
                    _idx = _idx_save
                end
            end
        end)
    end

    # Wildcard
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
                _add_route!(routes_by_method, line)
            elseif line.head == :call && line.args[1] == :group
                # Route groups: group("/prefix", ("GET", "/path") => handler, ...)
                prefix = line.args[2]
                for i in 3:length(line.args)
                    arg = line.args[i]
                    arg isa Expr || continue
                    _add_route!(routes_by_method, arg; prefix=string(prefix))
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
                # Strip query string — route matching ignores ?key=value
                for _qi in 1:_len
                    @inbounds codeunit(req.path, _qi) == UInt8('?') && (_len = _qi - 1; break)
                end
                _idx = Router.skip_slashes(req.path, _idx)
                $trie_code
            end
        end)
    end

    dispatch_body = Expr(:block, method_blocks..., :(return Response(404, "Not Found")))

    quote
        struct $(esc(app_type)) <: Router.AbstractApp end

        function Router.dispatch(::$(esc(app_type)), req::Request)
            _method = Methods.from_string(req.method)
            $dispatch_body
        end
    end
end

# Helper to extract route from a => expression
function _add_route!(routes_by_method, expr; prefix::String="")
    if expr isa Expr && expr.head == :call && expr.args[1] == :(=>) && length(expr.args) >= 3
        tuple_expr = expr.args[2]
        if tuple_expr isa Expr && length(tuple_expr.args) >= 2
            method = tuple_expr.args[1]
            path = string(prefix, tuple_expr.args[2])
            func = expr.args[3]
            if !haskey(routes_by_method, method)
                routes_by_method[method] = Vector{Tuple}()
            end
            push!(routes_by_method[method], (path, func))
        end
    end
end

end
