module Types

using PicoHTTPParser

export Request, Response, text, json

const Request = PicoHTTPParser.Request

struct Response
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
end

# Default constructor for easy text responses
function Response(status::Int, body::String, headers::Vector{Pair{String,String}}=Pair{String,String}[])
    return Response(status, headers, Vector{UInt8}(body))
end

function text(body::String; status::Int=200)
    return Response(status, ["Content-Type" => "text/plain"], Vector{UInt8}(body))
end

# Stub for json — implemented by CiroJSON extension
function json end

"""
    hasheader(resp::Response, key::String) -> Bool

Check if a response has a header with the given key.
"""
function hasheader(resp::Response, key::String)
    for (k, _) in resp.headers
        k == key && return true
    end
    return false
end

end
