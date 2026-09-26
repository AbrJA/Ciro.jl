# Public request value owned by Ciro. Parser-specific representations are
# converted at the boundary and are not exposed to handlers.
#
# Handlers receive views into the connection buffer by default (zero-copy);
# `body(ctx)`/`rawbody(ctx)` return owned copies. A view is only valid until
# the handler returns — retain a copy if it must escape.

using StringViews: StringView

const BufferView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}}

"""
    Request{M,T,P,Q,H,B}

A parsed request. Fields are abstract-string/vector-like so the same type
serves both the zero-copy path (views into the connection buffer) and the
materialized `Request(method, target; ...)` convenience constructor.
"""
struct Request{M <: AbstractString, T <: AbstractString,
               P <: AbstractString, Q <: AbstractString, H, B}
    method        :: M
    target        :: T
    path          :: P
    query         :: Q
    headers       :: H
    body          :: B
    minor_version :: UInt8
end

function _split_target(target::AbstractString)
    q = findfirst('?', target)
    q === nothing && return (target, SubString(target, 1, 0))
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
