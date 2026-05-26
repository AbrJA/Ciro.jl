"""
    Interfaces

Core abstractions for the Ciro web framework.

All concrete types are defined here so that downstream modules get a single,
type-stable contract. Extension points use abstract types + function stubs.
"""
module Interfaces

using PicoHTTPParser
using StringViews
using Base64

const Request = PicoHTTPParser.Request
export Request

# ══════════════════════════════════════════════════════════════════════════════
# HTTP Method Constants (bitmask-friendly: each method has a unique bit)
# ══════════════════════════════════════════════════════════════════════════════

module Methods
    const GET     = UInt8(1)
    const POST    = UInt8(2)
    const PUT     = UInt8(3)
    const DELETE  = UInt8(4)
    const PATCH   = UInt8(5)
    const HEAD    = UInt8(6)
    const OPTIONS = UInt8(7)
    const UNKNOWN = UInt8(0)

    "Convert method id to its bitmask position."
    @inline bitmask(m::UInt8)::UInt8 = m == 0 ? 0x00 : UInt8(1) << (m - 1)

    @inline function from_string(m::AbstractString)::UInt8
        len = ncodeunits(m)
        len == 3 && @inbounds(codeunit(m, 1)) == UInt8('G') && return GET
        len == 3 && @inbounds(codeunit(m, 1)) == UInt8('P') && @inbounds(codeunit(m, 2)) == UInt8('U') && return PUT
        len == 4 && @inbounds(codeunit(m, 1)) == UInt8('P') && @inbounds(codeunit(m, 2)) == UInt8('O') && return POST
        len == 4 && @inbounds(codeunit(m, 1)) == UInt8('H') && return HEAD
        len == 5 && @inbounds(codeunit(m, 1)) == UInt8('P') && return PATCH
        len == 6 && @inbounds(codeunit(m, 1)) == UInt8('D') && return DELETE
        len == 7 && @inbounds(codeunit(m, 1)) == UInt8('O') && return OPTIONS
        return UNKNOWN
    end

    const _STRINGS = ("UNKNOWN", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")

    @inline function to_string(m::UInt8)::String
        idx = Int(m) + 1
        return idx <= length(_STRINGS) ? _STRINGS[idx] : "UNKNOWN"
    end

    "Convert a bitmask of methods to a comma-separated Allow header value."
    function allow_header(mask::UInt8)::String
        parts = String[]
        for m in UInt8(1):UInt8(7)
            (mask & bitmask(m)) != 0 && push!(parts, to_string(m))
        end
        return join(parts, ", ")
    end
end

export Methods

# ══════════════════════════════════════════════════════════════════════════════
# Response Type
# ══════════════════════════════════════════════════════════════════════════════

struct Response
    status  :: Int
    headers :: Vector{Pair{String,String}}
    body    :: Vector{UInt8}
end

function Response(status::Int, body::String, headers::Vector{Pair{String,String}}=Pair{String,String}[])
    Response(status, headers, Vector{UInt8}(body))
end

# ── Response Builders ───────────────────────────────────────────────────────

@inline function text(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/plain; charset=utf-8"], Vector{UInt8}(body))
end

@inline function html(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/html; charset=utf-8"], Vector{UInt8}(body))
end

@inline function json(body::String; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], Vector{UInt8}(body))
end

@inline function json(body::Vector{UInt8}; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], body)
end

@inline function redirect(url::String; status::Int=302)
    Response(status, ["Location" => url], UInt8[])
end

@inline function fail(status::Int, message::String="")
    body = isempty(message) ? UInt8[] : Vector{UInt8}(message)
    Response(status, ["Content-Type" => "text/plain"], body)
end

export Response, text, html, json, redirect, fail

# ══════════════════════════════════════════════════════════════════════════════
# Header Utilities
# ══════════════════════════════════════════════════════════════════════════════

@inline function header(resp::Response, key::String, default::String="")::String
    for (k, v) in resp.headers
        k == key && return v
    end
    return default
end

@inline function header(req::Request, key::String, default::String="")::String
    for (k, v) in req.headers
        String(k) == key && return String(v)
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
        String(k) == key && return true
    end
    return false
end

export header, hasheader

# ══════════════════════════════════════════════════════════════════════════════
# Cookie Utilities
# ══════════════════════════════════════════════════════════════════════════════

"""Parse all cookies from a request into a Dict."""
function cookies(req::Request)::Dict{String,String}
    result = Dict{String,String}()
    cookie_hdr = header(req, "Cookie")
    isempty(cookie_hdr) && return result
    for pair in split(cookie_hdr, ';')
        kv = strip(pair)
        eq = findfirst('=', kv)
        eq === nothing && continue
        result[kv[1:eq-1]] = kv[eq+1:end]
    end
    return result
end

"""Get a single cookie value."""
@inline function cookie(req::Request, name::String, default::String="")::String
    cookie_hdr = header(req, "Cookie")
    isempty(cookie_hdr) && return default
    # Fast scan without allocating the full dict
    idx = findfirst(name * "=", cookie_hdr)
    idx === nothing && return default
    start = last(idx) + 1
    stop = findnext(';', cookie_hdr, start)
    stop === nothing && return cookie_hdr[start:end]
    return cookie_hdr[start:stop-1]
end

"""Build a Set-Cookie header value."""
function setcookie(name::String, value::String;
                   path::String="/", max_age::Int=-1,
                   httponly::Bool=true, secure::Bool=false,
                   samesite::String="Lax")::Pair{String,String}
    parts = ["$name=$value", "Path=$path", "SameSite=$samesite"]
    max_age >= 0 && push!(parts, "Max-Age=$max_age")
    httponly && push!(parts, "HttpOnly")
    secure && push!(parts, "Secure")
    return "Set-Cookie" => join(parts, "; ")
end

export cookies, cookie, setcookie

# ══════════════════════════════════════════════════════════════════════════════
# Body Utilities
# ══════════════════════════════════════════════════════════════════════════════

"""Get request body as String (lazy copy)."""
@inline function body(req::Request)::String
    String(copy(req.body))
end

"""Get raw request body bytes."""
@inline function rawbody(req::Request)::Vector{UInt8}
    Vector{UInt8}(req.body)
end

"""Get Content-Type of request."""
@inline function content_type(req::Request)::String
    header(req, "Content-Type")
end

export body, rawbody, content_type

# ══════════════════════════════════════════════════════════════════════════════
# Status Line Constants
# ══════════════════════════════════════════════════════════════════════════════

const STATUS = let
    v = fill("", 600)
    v[200] = "HTTP/1.1 200 OK\r\n"
    v[201] = "HTTP/1.1 201 Created\r\n"
    v[204] = "HTTP/1.1 204 No Content\r\n"
    v[301] = "HTTP/1.1 301 Moved Permanently\r\n"
    v[302] = "HTTP/1.1 302 Found\r\n"
    v[304] = "HTTP/1.1 304 Not Modified\r\n"
    v[400] = "HTTP/1.1 400 Bad Request\r\n"
    v[401] = "HTTP/1.1 401 Unauthorized\r\n"
    v[403] = "HTTP/1.1 403 Forbidden\r\n"
    v[404] = "HTTP/1.1 404 Not Found\r\n"
    v[405] = "HTTP/1.1 405 Method Not Allowed\r\n"
    v[408] = "HTTP/1.1 408 Request Timeout\r\n"
    v[413] = "HTTP/1.1 413 Content Too Large\r\n"
    v[422] = "HTTP/1.1 422 Unprocessable Entity\r\n"
    v[429] = "HTTP/1.1 429 Too Many Requests\r\n"
    v[500] = "HTTP/1.1 500 Internal Server Error\r\n"
    v[502] = "HTTP/1.1 502 Bad Gateway\r\n"
    v[503] = "HTTP/1.1 503 Service Unavailable\r\n"
    Tuple(v)
end

@inline function status(code::Int)::String
    if 1 <= code <= 600
        @inbounds line = STATUS[code]
        line !== "" && return line
    end
    return string("HTTP/1.1 ", code, " \r\n")
end

export status

# ══════════════════════════════════════════════════════════════════════════════
# Route Result — Type-stable return from route()
# ══════════════════════════════════════════════════════════════════════════════

"""
    RouteResult

Single concrete return type for `route()`. Encodes three outcomes without
type instability:

- **Match**: `handler !== nothing`
- **404 Not Found**: `handler === nothing && allowed == 0x00`
- **405 Method Not Allowed**: `handler === nothing && allowed != 0x00`

The `allowed` field is a bitmask of method IDs that DO exist for the path.
This enables generating the `Allow` header without allocation.
"""
struct RouteResult
    handler :: Any                          # callable or nothing
    params  :: Vector{Pair{Symbol,String}}  # captured path parameters
    allowed :: UInt8                        # method bitmask (0 = no path match)
end

# Constructors for each outcome
@inline RouteResult() = RouteResult(nothing, Pair{Symbol,String}[], 0x00)
@inline RouteResult(allowed::UInt8) = RouteResult(nothing, Pair{Symbol,String}[], allowed)
@inline RouteResult(handler, params::Vector{Pair{Symbol,String}}) = RouteResult(handler, params, 0x00)

# Status predicates — branch-free, inlinable
@inline matched(r::RouteResult)::Bool = r.handler !== nothing
@inline not_found(r::RouteResult)::Bool = r.handler === nothing && r.allowed == 0x00
@inline method_not_allowed(r::RouteResult)::Bool = r.handler === nothing && r.allowed != 0x00

export RouteResult, matched, not_found, method_not_allowed

# ══════════════════════════════════════════════════════════════════════════════
# Abstract Types — Extension Points
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractRouter

Interface for HTTP request dispatching.

Required: `route(router, method::UInt8, path::AbstractString) -> RouteResult`
Optional: `register!(router, method::UInt8, pattern::String, handler)`
"""
abstract type AbstractRouter end

function route end
function register! end

export AbstractRouter, route, register!

"""
    AbstractLogger

System-level logger (startup/shutdown/errors). NOT for per-request logging.
Required: `write(logger, level::Severity, msg::String)`
"""
abstract type AbstractLogger end

@enum Severity Debug=1 Info Warn Error Fatal

function write end

export AbstractLogger, Severity, Debug, Info, Warn, Error, Fatal, write

"""
    AbstractCatcher

Converts exceptions to HTTP responses safely.
Required: `intercept(catcher, err::Exception, req) -> Response`
"""
abstract type AbstractCatcher end

function intercept end

export AbstractCatcher, intercept

# ══════════════════════════════════════════════════════════════════════════════
# Default Implementations
# ══════════════════════════════════════════════════════════════════════════════

"""Silent logger — all calls optimize away."""
struct NullLogger <: AbstractLogger end
@inline write(::NullLogger, ::Severity, ::String) = nothing

"""Default error handler — never exposes internals (OWASP safe)."""
struct DefaultCatcher <: AbstractCatcher end
@inline function intercept(::DefaultCatcher, ::Exception, _)
    fail(500, "Internal Server Error")
end

export NullLogger, DefaultCatcher

# ══════════════════════════════════════════════════════════════════════════════
# Request Utilities
# ══════════════════════════════════════════════════════════════════════════════

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

export path, query, queryparams

end # module Interfaces
