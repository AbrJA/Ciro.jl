module QueryParsing

export parse_query, query_params, clean_path

"""
    query_params(req) -> Dict{String,String}

Parse query parameters from a request's path.
"""
function query_params(req)::Dict{String,String}
    path = req.path
    qmark = _find_qmark(path)
    qmark == 0 && return Dict{String,String}()
    return parse_query(view(path, qmark+1:ncodeunits(path)))
end

"""
    clean_path(req) -> SubString

Return the request path without the query string.
"""
function clean_path(req)
    path = req.path
    qmark = _find_qmark(path)
    qmark == 0 && return view(path, 1:ncodeunits(path))
    return view(path, 1:qmark-1)
end

@inline function _find_qmark(path::AbstractString)::Int
    len = ncodeunits(path)
    for i in 1:len
        @inbounds codeunit(path, i) == UInt8('?') && return i
    end
    return 0
end

"""
    parse_query(qs) -> Dict{String,String}

Parse a URL query string (`key=value&key2=value2`) into a Dict.
Handles URL-percent-decoding and `+` as space.
"""
function parse_query(qs::AbstractString)::Dict{String,String}
    params = Dict{String,String}()
    isempty(qs) && return params
    s = String(qs)
    for pair in split(s, '&'; keepempty=false)
        eq = findfirst('=', pair)
        if eq !== nothing
            params[urldecode(pair[1:eq-1])] = urldecode(pair[eq+1:end])
        else
            params[urldecode(pair)] = ""
        end
    end
    return params
end

"""
    urldecode(s) -> String

Decode a URL-percent-encoded string. Also converts `+` to space.
"""
function urldecode(s::AbstractString)::String
    io = IOBuffer(; sizehint=sizeof(s))
    bytes = codeunits(s)
    i = 1
    while i <= length(bytes)
        @inbounds b = bytes[i]
        if b == UInt8('%') && i + 2 <= length(bytes)
            hi = _hexval(bytes[i+1])
            lo = _hexval(bytes[i+2])
            if hi >= 0 && lo >= 0
                write(io, UInt8(hi << 4 | lo))
                i += 3; continue
            end
        elseif b == UInt8('+')
            write(io, UInt8(' ')); i += 1; continue
        end
        write(io, b); i += 1
    end
    return String(take!(io))
end

@inline function _hexval(b::UInt8)::Int
    UInt8('0') <= b <= UInt8('9') && return Int(b - UInt8('0'))
    UInt8('a') <= b <= UInt8('f') && return Int(b - UInt8('a') + 10)
    UInt8('A') <= b <= UInt8('F') && return Int(b - UInt8('A') + 10)
    return -1
end

end
