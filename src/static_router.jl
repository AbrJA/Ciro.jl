module StaticRouter

using StringViews
using ..Types # Request and Response are in Types module which is a sibling

export @routes, dispatch

abstract type AbstractApp end

function dispatch end

# --- Helper Functions ---

"""
    find_next_slash(path::AbstractString, start_idx::Int)

Scans `path` starting from `start_idx` for the next '/'.
Returns the index of the slash, or 0 if not found.
"""
function find_next_slash(path::AbstractString, start_idx::Int)
    len = ncodeunits(path)
    if start_idx > len
        return 0
    end

    # We iterate byte by byte. This is safe for UTF-8 properly formed paths
    # as 0x2f ('/') is ASCII and not a continuation byte.
    for i in start_idx:len
        if codeunit(path, i) == UInt8('/')
            return i
        end
    end
    return 0
end

"""
    skip_slashes(path::AbstractString, idx::Int)

Returns the index of the first non-slash character starting from `idx`.
"""
function skip_slashes(path::AbstractString, idx::Int)
    len = ncodeunits(path)
    while idx <= len && codeunit(path, idx) == UInt8('/')
        idx += 1
    end
    return idx
end

function parse_route_pattern(pattern::String)
    # Split using Base.split to analyze the pattern structure at compile time
    raw_segments = split(pattern, "/", keepempty=false)
    segments = []

    for seg in raw_segments
        if startswith(seg, ":")
            # Variable: "user" in ":user"
            push!(segments, (:variable, Symbol(seg[2:end])))
        else
            # Static: "user"
            push!(segments, (:static, seg))
        end
    end
    return segments
end

# --- Macro Implementation ---

macro routes(app_type::Symbol, block)
    routes = []
    if block.head == :block
        for line in block.args
            if line isa Expr && line.head == :call && line.args[1] == :(=>)
                if length(line.args[2].args) == 2
                    (method, path) = line.args[2].args
                    func = line.args[3]
                    push!(routes, (method, path, func))
                end
            end
        end
    end

    fallback = :(return Response(404, "Not Found"))

    # Build the dispatch logic from bottom up (reverse order of routes)
    current_expr = fallback

    for (method, path, func) in reverse(routes)
        segments = parse_route_pattern(path)

        # Identify variables in order
        vars_to_pass = [val for (type, val) in segments if type == :variable]

        # 1. The Action: Call the handler
        inner_body = quote
            return $(esc(func))(req, $(vars_to_pass...))
        end

        # 2. Final Check: Ensure we consumed the entire path
        # After matching all segments, idx should be past the end
        inner_body = quote
            if idx > len
                $inner_body
            end
        end

        # 3. Match Segments (Reverse)
        for (seg_type, val) in reverse(segments)
            if seg_type == :static
                seg_str = val
                inner_body = quote
                    # Find end of this segment
                    end_idx = StaticRouter.find_next_slash(req.path, idx)
                    if end_idx == 0
                        end_idx = len + 1
                    end

                    # Check length match
                    seg_len = end_idx - idx

                    # Content check: fast view check
                    if seg_len == $(length(seg_str)) &&
                       (view(req.path, idx:end_idx-1) == $seg_str)

                        # Move past this segment
                        idx = end_idx
                        # Skip any separators (mimicking split keepempty=false behavior for //)
                        idx = StaticRouter.skip_slashes(req.path, idx)

                        $inner_body
                    end
                end
            else
                # Variable
                var_sym = val
                inner_body = quote
                    end_idx = StaticRouter.find_next_slash(req.path, idx)
                    if end_idx == 0
                        end_idx = len + 1
                    end

                    if idx < end_idx
                        # Capture variable as SubString (zero-copy view)
                        # Use `var_sym` as the local variable name
                        $(var_sym) = view(req.path, idx:end_idx-1)

                        idx = end_idx
                        idx = StaticRouter.skip_slashes(req.path, idx)

                        $inner_body
                    end
                end
            end
        end

        # 4. Method Check and Initialization
        current_expr = quote
            if req.method == $method
                # Initialize state for this route check
                idx = 1
                len = ncodeunits(req.path)

                # Global preamble: skip leading slashes to normalize "/path" vs "path" or "//path"
                idx = StaticRouter.skip_slashes(req.path, idx)

                # Enter segment matching
                $inner_body
            end

            # If we fall through (method mismatch or path mismatch), go to next route
            $current_expr
        end
    end

    # Return the Type definition and the dispatch function
    quote
        struct $(esc(app_type)) <: StaticRouter.AbstractApp end

        function StaticRouter.dispatch(::$(esc(app_type)), req)
            $current_expr
        end
    end
end

end
