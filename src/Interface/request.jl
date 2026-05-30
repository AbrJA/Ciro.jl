# ══════════════════════════════════════════════════════════════════════════════
# Request Utilities — headers, cookies, body, path, query, params
# ══════════════════════════════════════════════════════════════════════════════

# ── Header Utilities ────────────────────────────────────────────────────────

"""Zero-allocation case-insensitive header key comparison."""
@inline function _hdr_key_eq(a, key::String)::Bool
    ncodeunits(a) != ncodeunits(key) && return false
    for i in 1:ncodeunits(key)
        ca = @inbounds codeunit(a, i)
        cb = @inbounds codeunit(key, i)
        # ASCII lowercase: set bit 5 for alpha chars
        ca_lower = (UInt8('A') <= ca <= UInt8('Z')) ? (ca | 0x20) : ca
        cb_lower = (UInt8('A') <= cb <= UInt8('Z')) ? (cb | 0x20) : cb
        ca_lower != cb_lower && return false
    end
    return true
end

@inline function header(resp::Response, key::String, default::String="")::String
    for (k, v) in resp.headers
        k == key && return v
    end
    return default
end

@inline function header(req::Request, key::String, default::String="")::String
    for (k, v) in req.headers
        _hdr_key_eq(k, key) && return String(v)
    end
    return default
end

@inline function hasheader(resp::Response, key::String)::Bool
    for (k, _) in resp.headers
        k == key && return true
    end
    return false
end

@inline function hasheader(req::Request, key::String)::Bool
    for (k, _) in req.headers
        _hdr_key_eq(k, key) && return true
    end
    return false
end

# Context overloads — delegate to ctx.req
header(ctx::Context, key::String, default::String="")::String  = header(ctx.req, key, default)
hasheader(ctx::Context, key::String)::Bool                       = hasheader(ctx.req, key)

export header, hasheader

# ── Body Utilities ──────────────────────────────────────────────────────────

"""Get request body as String (lazy copy)."""
function body(req::Request)::String
    String(copy(req.body))
end

"""Get raw request body bytes."""
function rawbody(req::Request)::Vector{UInt8}
    Vector{UInt8}(req.body)
end

"""Get Content-Type of request."""
function content_type(req::Request)::String
    header(req, "Content-Type")
end

# Context overloads
body(ctx::Context)::String         = body(ctx.req)
rawbody(ctx::Context)::Vector{UInt8} = rawbody(ctx.req)
content_type(ctx::Context)::String  = content_type(ctx.req)

export body, rawbody, content_type

# ── Path & Query ────────────────────────────────────────────────────────────

"""Get the path portion (before ?) from a request."""
@inline function path(req::Request)::SubString
    p = req.path
    len = ncodeunits(p)
    for i in 1:len
        @inbounds codeunit(p, i) == UInt8('?') && return SubString(String(p), 1, i - 1)
    end
    return SubString(String(p), 1, len)
end

"""Get the query string (after ?) from a request."""
@inline function query(req::Request)::String
    p = req.path
    len = ncodeunits(p)
    for i in 1:len
        @inbounds codeunit(p, i) == UInt8('?') && return String(p)[i+1:end]
    end
    return ""
end

"""Parse query string into key-value pairs."""
function queryparams(req::Request)::Dict{String,String}
    qs = query(req)
    result = Dict{String,String}()
    isempty(qs) && return result
    for pair in split(qs, '&')
        eq = findfirst('=', pair)
        eq === nothing && (result[pair] = ""; continue)
        result[pair[1:eq-1]] = pair[eq+1:end]
    end
    return result
end

# Context overloads
@inline path(ctx::Context)                             = path(ctx.req)
@inline query(ctx::Context)::String                    = query(ctx.req)
queryparams(ctx::Context)::Dict{String,String}         = queryparams(ctx.req)

export path, query, queryparams

# ── Route Parameter Access ──────────────────────────────────────────────────

"""Get a route parameter by name as `String`. Returns `default` if not present."""
@inline function param(ctx::Context, name::Symbol, default::String="")::String
    for (k, v) in ctx.params
        k === name && return v
    end
    return default
end

"""Get a route parameter parsed to `T`. Returns `nothing` if missing or unparseable."""
@inline function param(ctx::Context, ::Type{T}, name::Symbol)::Union{T,Nothing} where T
    for (k, v) in ctx.params
        k === name || continue
        return tryparse(T, v)
    end
    return nothing
end

export param
