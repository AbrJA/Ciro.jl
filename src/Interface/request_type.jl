# Public request value owned by Ciro. Parser-specific representations are
# converted at the boundary and are not exposed to handlers.
#
# Handlers receive views into the connection buffer by default (zero-copy);
# `body(ctx)`/`rawbody(ctx)` return owned copies. A view is only valid until
# the handler returns — retain a copy if it must escape.

using StringViews: StringView

const BufferView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int}},true}}

"""
    Headers{H,B}

Lazy view of a parsed field section: `length`, iteration and indexing yield
`name => value` pairs of views into the connection buffer, without
materializing the list. Valid while the request is being handled (synchronous
dispatch); `collect(req.headers)` retains an owned copy.
"""
struct Headers{H,B}
    hbuf :: H
    buf  :: B
    n    :: Int
end

Base.length(h::Headers)::Int = h.n
Base.isempty(h::Headers)::Bool = h.n == 0

@inline function Base.getindex(h::Headers, i::Integer)::Pair{BufferView,BufferView}
    return PicoHTTPParser.header_name(h.hbuf, i, h.buf) =>
           PicoHTTPParser.header_value(h.hbuf, i, h.buf)
end

function Base.iterate(h::Headers, state::Int=1)
    state > h.n && return nothing
    return (h[state], state + 1)
end

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

"""
    copy(request::Request) -> Request

Owned, materialized copy of a request. Use this to retain anything past the
handler's return: the request a handler receives points into the connection
buffer, which is reused for the next request.
"""
function Base.copy(req::Request)
    return Request(String(req.method), String(req.target),
                   String(req.path), String(req.query),
                   Pair{String,String}[String(k) => String(v) for (k, v) in req.headers],
                   Vector{UInt8}(req.body), req.minor_version)
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
