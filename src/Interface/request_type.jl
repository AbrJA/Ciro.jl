# Public request value owned by Ciro. Parser-specific representations are
# converted at the boundary and are not exposed to handlers.

struct Request
    method         :: String
    target         :: String
    path           :: String
    query          :: String
    headers        :: Vector{Pair{String,String}}
    body           :: Vector{UInt8}
    minor_version  :: UInt8
end

function Request(raw::PicoHTTPParser.Request)
    target = String(raw.path)
    query_start = findfirst(==(UInt8('?')), codeunits(target))
    path = query_start === nothing ? target : target[1:query_start-1]
    query = query_start === nothing ? "" : target[query_start+1:end]
    headers = Pair{String,String}[String(k) => String(v) for (k, v) in raw.headers]
    body = Vector{UInt8}(raw.body)
    return Request(String(raw.method), target, path, query, headers, body,
                   UInt8(raw.minor_version))
end

function Request(method::AbstractString, target::AbstractString;
                 headers::AbstractVector{<:Pair}=Pair{String,String}[],
                 body::AbstractVector{UInt8}=UInt8[],
                 minor_version::Integer=1)
    target_string = String(target)
    query_start = findfirst(==(UInt8('?')), codeunits(target_string))
    path = query_start === nothing ? target_string : target_string[1:query_start-1]
    query = query_start === nothing ? "" : target_string[query_start+1:end]
    return Request(String(method), target_string, path, query,
                   Pair{String,String}[String(k) => String(v) for (k, v) in headers],
                   Vector{UInt8}(body), UInt8(minor_version))
end
