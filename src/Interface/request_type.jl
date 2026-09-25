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

function _split_target(target::String)
    q = findfirst('?', target)
    q === nothing && return (target, "")
    return (target[1:prevind(target, q)], target[nextind(target, q):end])
end

function Request(raw::PicoHTTPParser.Request)
    target = String(raw.target)
    path, query = _split_target(target)
    headers = Pair{String,String}[String(k) => String(v) for (k, v) in raw.headers]
    body = Vector{UInt8}(raw.body)
    return Request(String(raw.method), target, path, query, headers, body,
                   UInt8(raw.minor_version))
end

function Request(method::AbstractString, target::AbstractString;
                 headers::AbstractVector{<:Pair}=Pair{String,String}[],
                 body::AbstractVector{UInt8}=UInt8[],
                 minor_version::Integer=1)
    target_string::String = String(target)
    isempty(method) && throw(ArgumentError("request method cannot be empty"))
    startswith(target_string, '/') || throw(ArgumentError("request target must start with '/'"))
    path, query = _split_target(target_string)
    return Request(String(method), target_string, path, query,
                   Pair{String,String}[String(k) => String(v) for (k, v) in headers],
                   Vector{UInt8}(body), UInt8(minor_version))
end
