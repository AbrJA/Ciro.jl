module BodyParsing

using ..Types
using ..QueryParsing: parse_query

export body_string, body_bytes, parse_form

"""
    body_string(req) -> String

Return the request body as a UTF-8 String.
"""
@inline function body_string(req)::String
    return String(copy(req.body))
end

"""
    body_bytes(req) -> Vector{UInt8}

Return the request body as a byte vector (copy).
"""
@inline function body_bytes(req)::Vector{UInt8}
    return copy(req.body)
end

"""
    parse_form(req) -> Dict{String,String}

Parse URL-encoded form data from the request body.
Returns empty Dict if Content-Type is not `application/x-www-form-urlencoded`.
"""
function parse_form(req)::Dict{String,String}
    ct = _get_content_type(req)
    startswith(ct, "application/x-www-form-urlencoded") || return Dict{String,String}()
    return parse_query(body_string(req))
end

function _get_content_type(req)::String
    for (k, v) in req.headers
        String(k) == "Content-Type" && return String(v)
    end
    return ""
end

end
