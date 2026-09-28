# ══════════════════════════════════════════════════════════════════════════════
# Response Type & Builders
# ══════════════════════════════════════════════════════════════════════════════

"""
    Response

HTTP response with status code, headers, and body bytes.
Body is stored as `Vector{UInt8}` for type stability on the serialization path.

Header names must be RFC 9110 tokens and values must not contain CR, LF or NUL;
violations throw `ArgumentError` at construction, which closes the header
injection path before anything reaches the wire.
"""
struct Response
    status  :: Int
    headers :: Vector{Pair{String,String}}
    body    :: Vector{UInt8}

    function Response(status::Int, headers::Vector{Pair{String,String}}, body::Vector{UInt8})
        _validate_headers(headers)
        return new(status, headers, body)
    end
end

Response(status::Int, headers::Vector{Pair{String,String}}, body::String) =
    Response(status, headers, Vector{UInt8}(body))

@inline function _is_token_byte(b::UInt8)::Bool
    (UInt8('a') <= b <= UInt8('z')) && return true
    (UInt8('A') <= b <= UInt8('Z')) && return true
    (UInt8('0') <= b <= UInt8('9')) && return true
    return b in (UInt8('!'), UInt8('#'), UInt8('$'), UInt8('%'), UInt8('&'),
                 UInt8('\''), UInt8('*'), UInt8('+'), UInt8('-'), UInt8('.'),
                 UInt8('^'), UInt8('_'), UInt8('`'), UInt8('|'), UInt8('~'))
end

@inline function _valid_header_name(k::String)::Bool
    isempty(k) && return false
    for i in 1:ncodeunits(k)
        _is_token_byte(@inbounds codeunit(k, i)) || return false
    end
    return true
end

@inline function _valid_header_value(v::String)::Bool
    for i in 1:ncodeunits(v)
        b = @inbounds codeunit(v, i)
        (b == 0x0d || b == 0x0a || b == 0x00) && return false
    end
    return true
end

function _validate_headers(headers::Vector{Pair{String,String}})
    for (k, v) in headers
        _valid_header_name(k) ||
            throw(ArgumentError("invalid HTTP header name: $(repr(k))"))
        _valid_header_value(v) ||
            throw(ArgumentError("invalid HTTP header value for '$k': CR/LF/NUL are not allowed"))
    end
    return nothing
end

# ── Response Builders ───────────────────────────────────────────────────────

function text(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/plain; charset=utf-8"], body)
end

function html(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/html; charset=utf-8"], body)
end

function json(body::String; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], body)
end

function json(body::Vector{UInt8}; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], body)
end

function redirect(url::String; status::Int=302)
    Response(status, ["Location" => url], "")
end

function fail(status::Int, message::String="")
    Response(status, ["Content-Type" => "text/plain"], message)
end

export Response, text, html, json, redirect, fail

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
