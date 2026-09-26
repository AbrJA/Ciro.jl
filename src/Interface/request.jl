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

@inline header(req::PicoHTTPParser.Request, key::String, default::String="")::String =
    header(Request(req), key, default)

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

@inline hasheader(req::PicoHTTPParser.Request, key::String)::Bool =
    hasheader(Request(req), key)

# Context overloads — delegate to ctx.request
header(ctx::RequestContext, key::String, default::String="")::String  = header(ctx.request, key, default)
hasheader(ctx::RequestContext, key::String)::Bool                       = hasheader(ctx.request, key)

export header, hasheader

# ── Body Utilities ──────────────────────────────────────────────────────────

"""Get request body as String (one owned copy, safe to retain)."""
function body(req::Request)::String
    String(Vector{UInt8}(req.body))
end

body(req::PicoHTTPParser.Request)::String = body(Request(req))

"""Get raw request body bytes (one owned copy, safe to retain)."""
function rawbody(req::Request)::Vector{UInt8}
    Vector{UInt8}(req.body)
end

rawbody(req::PicoHTTPParser.Request)::Vector{UInt8} = rawbody(Request(req))

"""Get Content-Type of request."""
function content_type(req::Request)::String
    header(req, "Content-Type")
end

content_type(req::PicoHTTPParser.Request)::String = content_type(Request(req))

# Context overloads
body(ctx::RequestContext)::String         = body(ctx.request)
rawbody(ctx::RequestContext)::Vector{UInt8} = rawbody(ctx.request)
content_type(ctx::RequestContext)::String  = content_type(ctx.request)

export body, rawbody, content_type

# ── Path & Query ────────────────────────────────────────────────────────────

"""Get the path portion (before `?`) from a request."""
@inline path(req::Request) = req.path

@inline path(req::PicoHTTPParser.Request) = path(Request(req))

"""Get the query string (after `?`) from a request."""
@inline query(req::Request) = req.query

@inline query(req::PicoHTTPParser.Request)::String = query(Request(req))

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

queryparams(req::PicoHTTPParser.Request)::Dict{String,String} = queryparams(Request(req))

# Context overloads
@inline path(ctx::RequestContext)                             = path(ctx.request)
@inline query(ctx::RequestContext)::String                    = query(ctx.request)
queryparams(ctx::RequestContext)::Dict{String,String}         = queryparams(ctx.request)

export path, query, queryparams

# ── Route Parameter Access ──────────────────────────────────────────────────

"""Get a route parameter by name as `String`. Returns `default` if not present."""
@inline function param(ctx::RequestContext, name::Symbol, default::String="")::String
    for (k, v) in ctx.params
        k === name && return v
    end
    return default
end

"""Get a route parameter parsed to `T`. Returns `nothing` if missing or unparseable."""
@inline function param(ctx::RequestContext, ::Type{T}, name::Symbol)::Union{T,Nothing} where T
    for (k, v) in ctx.params
        k === name || continue
        return tryparse(T, v)
    end
    return nothing
end

export param
