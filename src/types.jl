module Types

using PicoHTTPParser
using JSON

export Request, Response, json, text

const Request = PicoHTTPParser.Request

struct Response
    status::Int
    headers::Dict{String,String}
    body::Vector{UInt8}
end

# Default constructor for easy text responses
function Response(status::Int, body::String, headers::Dict{String,String}=Dict{String,String}())
    return Response(status, headers, Vector{UInt8}(body))
end

function text(body::String; status=200)
    return Response(status, Dict("Content-Type" => "text/plain"), Vector{UInt8}(body))
end

function json(data; status=200)
    body_str = JSON.json(data)
    return Response(status, Dict("Content-Type" => "application/json"), Vector{UInt8}(body_str))
end

end
