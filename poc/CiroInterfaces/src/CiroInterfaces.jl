"""
    CiroInterfaces

The interface package for the Ciro ecosystem.
Uses PicoHTTPParser.Request directly — zero-copy, zero-allocation parsing.

# Extension Guide

To create a new router:
```julia
using CiroInterfaces
struct MyRouter <: AbstractRouter end
CiroInterfaces.route(r::MyRouter, method::UInt8, path) = ...
```
"""
module CiroInterfaces

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

@inline function json_response(body::String; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], Vector{UInt8}(body))
end

@inline function json_response(body::Vector{UInt8}; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], body)
end

@inline function redirect(url::String; status::Int=302)
    Response(status, ["Location" => url], UInt8[])
end

@inline function error_response(status::Int, message::String="")
    body = isempty(message) ? UInt8[] : Vector{UInt8}(message)
    Response(status, ["Content-Type" => "text/plain"], body)
end

export Response, text, html, json_response, redirect, error_response

# ── Header utilities ────────────────────────────────────────────────────────

@inline function hasheader(resp::Response, key::String)::Bool
    for (k, _) in resp.headers
        k == key && return true
    end
    return false
end

@inline function getheader(resp::Response, key::String, default::String="")::String
    for (k, v) in resp.headers
        k == key && return v
    end
    return default
end

"""Get header from PicoHTTPParser.Request (StringView comparison)."""
@inline function req_header(req::Request, key::String, default::String="")::String
    for (k, v) in req.headers
        String(k) == key && return String(v)
    end
    return default
end

export hasheader, getheader, req_header

# ══════════════════════════════════════════════════════════════════════════════
# Status Line Constants (zero-allocation for common codes)
# ══════════════════════════════════════════════════════════════════════════════

const _SL_200 = "HTTP/1.1 200 OK\r\n"
const _SL_201 = "HTTP/1.1 201 Created\r\n"
const _SL_204 = "HTTP/1.1 204 No Content\r\n"
const _SL_301 = "HTTP/1.1 301 Moved Permanently\r\n"
const _SL_302 = "HTTP/1.1 302 Found\r\n"
const _SL_304 = "HTTP/1.1 304 Not Modified\r\n"
const _SL_400 = "HTTP/1.1 400 Bad Request\r\n"
const _SL_401 = "HTTP/1.1 401 Unauthorized\r\n"
const _SL_403 = "HTTP/1.1 403 Forbidden\r\n"
const _SL_404 = "HTTP/1.1 404 Not Found\r\n"
const _SL_405 = "HTTP/1.1 405 Method Not Allowed\r\n"
const _SL_413 = "HTTP/1.1 413 Content Too Large\r\n"
const _SL_422 = "HTTP/1.1 422 Unprocessable Entity\r\n"
const _SL_429 = "HTTP/1.1 429 Too Many Requests\r\n"
const _SL_500 = "HTTP/1.1 500 Internal Server Error\r\n"
const _SL_502 = "HTTP/1.1 502 Bad Gateway\r\n"
const _SL_503 = "HTTP/1.1 503 Service Unavailable\r\n"

@inline function status_line(status::Int)::String
    status == 200 && return _SL_200
    status == 201 && return _SL_201
    status == 204 && return _SL_204
    status == 301 && return _SL_301
    status == 302 && return _SL_302
    status == 304 && return _SL_304
    status == 400 && return _SL_400
    status == 401 && return _SL_401
    status == 403 && return _SL_403
    status == 404 && return _SL_404
    status == 405 && return _SL_405
    status == 413 && return _SL_413
    status == 422 && return _SL_422
    status == 429 && return _SL_429
    status == 500 && return _SL_500
    status == 502 && return _SL_502
    status == 503 && return _SL_503
    return string("HTTP/1.1 ", status, " \r\n")
end

export status_line

# ══════════════════════════════════════════════════════════════════════════════
# Abstract Types — Extension Points
# ══════════════════════════════════════════════════════════════════════════════

"""
    AbstractRouter

Interface for HTTP request dispatching.

Required: `route(router, method::UInt8, path::AbstractString) -> Union{Nothing, handler}`
Optional: `add_route!(router, method::UInt8, pattern::String, handler)`
"""
abstract type AbstractRouter end

function route end
function add_route! end

export AbstractRouter, route, add_route!

"""
    AbstractLogger

System-level logger (startup/shutdown/errors). NOT for per-request logging.
Required: `log_event(logger, level::LogLevel, msg::String)`
"""
abstract type AbstractLogger end

@enum LogLevel DEBUG=1 INFO=2 WARN=3 ERROR_LEVEL=4 FATAL=5

function log_event end

export AbstractLogger, LogLevel, DEBUG, INFO, WARN, ERROR_LEVEL, FATAL, log_event

"""
    AbstractErrorHandler

Converts exceptions to HTTP responses safely.
Required: `handle_error(handler, err::Exception, req) -> Response`
"""
abstract type AbstractErrorHandler end

function handle_error end

export AbstractErrorHandler, handle_error

# ══════════════════════════════════════════════════════════════════════════════
# Zero-Cost Defaults (compile away completely)
# ══════════════════════════════════════════════════════════════════════════════

"""Silent logger — all calls optimize away."""
struct NullLogger <: AbstractLogger end
@inline log_event(::NullLogger, ::LogLevel, ::String) = nothing

"""Default error handler — never exposes internals (OWASP safe)."""
struct DefaultErrorHandler <: AbstractErrorHandler end
@inline function handle_error(::DefaultErrorHandler, ::Exception, _)
    error_response(500, "Internal Server Error")
end

export NullLogger, DefaultErrorHandler

# ══════════════════════════════════════════════════════════════════════════════
# Query/Path Utilities
# ══════════════════════════════════════════════════════════════════════════════

"""Get the path portion (before ?) from a request."""
@inline function clean_path(req::Request)::SubString
    path = req.path
    len = ncodeunits(path)
    for i in 1:len
        @inbounds codeunit(path, i) == UInt8('?') && return SubString(String(path), 1, i - 1)
    end
    return SubString(String(path), 1, len)
end

"""Get the query string (after ?) from a request."""
@inline function query_string(req::Request)::String
    path = req.path
    len = ncodeunits(path)
    for i in 1:len
        @inbounds codeunit(path, i) == UInt8('?') && return String(path)[i+1:end]
    end
    return ""
end

export clean_path, query_string

end # module CiroInterfaces
