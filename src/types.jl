module Types

using PicoHTTPParser

export Request, Response, text, json, html

const Request = PicoHTTPParser.Request

# --- HTTP Method Constants (for fast comparison via UInt8 tag) ---

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
        len == 3 && codeunit(m, 1) == UInt8('G') && return GET
        len == 3 && codeunit(m, 1) == UInt8('P') && codeunit(m, 2) == UInt8('U') && return PUT
        len == 4 && codeunit(m, 1) == UInt8('P') && codeunit(m, 2) == UInt8('O') && return POST
        len == 4 && codeunit(m, 1) == UInt8('H') && return HEAD
        len == 5 && codeunit(m, 1) == UInt8('P') && return PATCH
        len == 6 && codeunit(m, 1) == UInt8('D') && return DELETE
        len == 7 && codeunit(m, 1) == UInt8('O') && return OPTIONS
        return UNKNOWN
    end
end

export Methods

# --- Response Type ---

struct Response
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
end

# Convenience: Response(status, body) or Response(status, body, headers)
function Response(status::Int, body::String, headers::Vector{Pair{String,String}}=Pair{String,String}[])
    return Response(status, headers, Vector{UInt8}(body))
end

# --- Response Builders ---

@inline function text(body::String; status::Int=200)
    return Response(status, ["Content-Type" => "text/plain; charset=utf-8"], Vector{UInt8}(body))
end

@inline function html(body::String; status::Int=200)
    return Response(status, ["Content-Type" => "text/html; charset=utf-8"], Vector{UInt8}(body))
end

# Stub for json — implemented by CiroJSON extension
function json end

# --- Header Utilities ---

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

# --- Status Line Constants (zero-allocation for common codes) ---

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
const _SL_409 = "HTTP/1.1 409 Conflict\r\n"
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
    status == 409 && return _SL_409
    status == 422 && return _SL_422
    status == 429 && return _SL_429
    status == 500 && return _SL_500
    status == 502 && return _SL_502
    status == 503 && return _SL_503
    return "HTTP/1.1 $status Unknown\r\n"
end

end
