# ══════════════════════════════════════════════════════════════════════════════
# Response Type & Builders
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

function text(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/plain; charset=utf-8"], Vector{UInt8}(body))
end

function html(body::String; status::Int=200)
    Response(status, ["Content-Type" => "text/html; charset=utf-8"], Vector{UInt8}(body))
end

function json(body::String; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], Vector{UInt8}(body))
end

function json(body::Vector{UInt8}; status::Int=200)
    Response(status, ["Content-Type" => "application/json; charset=utf-8"], body)
end

function redirect(url::String; status::Int=302)
    Response(status, ["Location" => url], UInt8[])
end

function fail(status::Int, message::String="")
    body = isempty(message) ? UInt8[] : Vector{UInt8}(message)
    Response(status, ["Content-Type" => "text/plain"], body)
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
