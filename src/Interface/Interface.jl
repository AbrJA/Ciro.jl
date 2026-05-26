"""
    Interfaces

The interface package for the Ciro ecosystem.
Uses PicoHTTPParser.Request directly — zero-copy, zero-allocation parsing.

# Extension Guide

To create a new router:
```julia
using Interfaces
struct MyRouter <: AbstractRouter end
Interfaces.route(r::MyRouter, method::UInt8, path) = ...
```
"""
module Interfaces

using PicoHTTPParser
using StringViews

# Re-export PicoHTTPParser.Request as THE request type
const Request = PicoHTTPParser.Request
export Request

# ══════════════════════════════════════════════════════════════════════════════
# HTTP Method Constants
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

# ── Header utilities ────────────────────────────────────────────────────────

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
# Status Line Constants (zero-allocation for common codes)
# ══════════════════════════════════════════════════════════════════════════════

const STATUS = let
    v = fill("", 503)
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
    v[413] = "HTTP/1.1 413 Content Too Large\r\n"
    v[422] = "HTTP/1.1 422 Unprocessable Entity\r\n"
    v[429] = "HTTP/1.1 429 Too Many Requests\r\n"
    v[500] = "HTTP/1.1 500 Internal Server Error\r\n"
    v[502] = "HTTP/1.1 502 Bad Gateway\r\n"
    v[503] = "HTTP/1.1 503 Service Unavailable\r\n"
    Tuple(v)
end

# 2. The high-performance function
@inline function status(code::Int)::String
    if 200 <= code <= 503
        @inbounds line = STATUS[code]
        line !== "" && return line
    end
    return string("HTTP/1.1 ", code, " \r\n")
end

export status

# ══════════════════════════════════════════════════════════════════════════════
# Abstract Types — Extension Points
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractRouter

Interface for HTTP request dispatching.

Required: `route(router, method::UInt8, path::AbstractString) -> Union{Nothing, handler}`
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
# Zero-Cost Defaults (compile away completely)
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
# Query/Path Utilities
# ══════════════════════════════════════════════════════════════════════════════

"""Get the path portion (before ?) from a request."""
@inline function path(req::Request)::SubString
    path = req.path
    len = ncodeunits(path)
    for i in 1:len
        @inbounds codeunit(path, i) == UInt8('?') && return SubString(String(path), 1, i - 1)
    end
    return SubString(String(path), 1, len)
end

"""Get the query string (after ?) from a request."""
@inline function query(req::Request)::String
    path = req.path
    len = ncodeunits(path)
    for i in 1:len
        @inbounds codeunit(path, i) == UInt8('?') && return String(path)[i+1:end]
    end
    return ""
end

export path, query

end # module Interfaces
