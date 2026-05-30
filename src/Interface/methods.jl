# ══════════════════════════════════════════════════════════════════════════════
# HTTP Method Constants (bitmask-friendly: each method has a unique bit)
# ══════════════════════════════════════════════════════════════════════════════

module Methods
    const GET     = UInt8(1)
    const POST    = UInt8(2)
    const PUT     = UInt8(3)
    const DELETE  = UInt8(4)
    const PATCH   = UInt8(5)
    const HEAD    = UInt8(6)
    const OPTIONS = UInt8(7)
    const UNKNOWN = UInt8(0)

    "Convert method id to its bitmask position."
    @inline bitmask(m::UInt8)::UInt8 = m == 0 ? 0x00 : UInt8(1) << (m - 1)

    @inline function from_string(m::AbstractString)::UInt8
        len = ncodeunits(m)
        len == 3 && @inbounds(codeunit(m, 1)) == UInt8('G') && return GET
        len == 3 && @inbounds(codeunit(m, 1)) == UInt8('P') && @inbounds(codeunit(m, 2)) == UInt8('U') && return PUT
        len == 4 && @inbounds(codeunit(m, 1)) == UInt8('P') && @inbounds(codeunit(m, 2)) == UInt8('O') && return POST
        len == 4 && @inbounds(codeunit(m, 1)) == UInt8('H') && return HEAD
        len == 5 && @inbounds(codeunit(m, 1)) == UInt8('P') && return PATCH
        len == 6 && @inbounds(codeunit(m, 1)) == UInt8('D') && return DELETE
        len == 7 && @inbounds(codeunit(m, 1)) == UInt8('O') && return OPTIONS
        return UNKNOWN
    end

    const _STRINGS = ("UNKNOWN", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")

    @inline function to_string(m::UInt8)::String
        idx = Int(m) + 1
        return idx <= length(_STRINGS) ? _STRINGS[idx] : "UNKNOWN"
    end

    "Convert a bitmask of methods to a comma-separated Allow header value."
    function allow_header(mask::UInt8)::String
        parts = String[]
        for m in UInt8(1):UInt8(7)
            (mask & bitmask(m)) != 0 && push!(parts, to_string(m))
        end
        return join(parts, ", ")
    end
end

export Methods
