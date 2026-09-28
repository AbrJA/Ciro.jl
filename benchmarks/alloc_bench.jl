#!/usr/bin/env julia
# Hot-path allocation budgets. Exits non-zero on regression.
# Run with: julia --project=. benchmarks/alloc_bench.jl
using Ciro
using Ciro.HTTP: HTTPConn, _build_request, parse_request_head!, head_length

failed = Ref(false)

function check(name::String, budget::Int, f)
    f()                     # warmup
    bytes = @allocated f()
    status = bytes <= budget ? "ok" : "OVER BUDGET"
    println(rpad(name, 28), lpad(bytes, 6), " B   budget ", lpad(budget, 5), " B   ", status)
    bytes <= budget || (failed[] = true)
    return
end

# Routing

router = Trie()
get!(router, "/fixed", _ -> text("ok"))
get!(router, "/users/:id::Int", _ -> text("u"))
post!(router, "/data", _ -> text("created"; status=201))
freeze!(router)

# Consume the result inside the measured closure: returning the non-isbits
# RouteResult across the measurement boundary boxes it on Julia < 1.12, which
# would measure the harness rather than routing.
check("route static", 64, () -> (res = route(router, Methods.GET, "/fixed"); matched(res) ? 1 : 0))
check("route param", 256, () -> (res = route(router, Methods.GET, "/users/42"); length(res.params)))

# The served path reuses a per-connection scratch: no allocation at all.
const _CAPTURES = Pair{Symbol,UnitRange{Int}}[]
check("route! static", 16, () -> (res = route!(router, Methods.GET, "/fixed", _CAPTURES); matched(res) ? 1 : 0))
check("route! param", 16, () -> (res = route!(router, Methods.GET, "/users/42", _CAPTURES); length(res.params)))

# Request construction (zero-copy views)

raw = Vector{UInt8}(
    "GET /users/42 HTTP/1.1\r\nHost: x\r\nAccept: */*\r\nUser-Agent: bench\r\n\r\n")
st = HTTPConn(nothing)
append!(st.rbuf, raw)
st.rlen = length(raw)
parse_request_head!(st.hbuf, st.rbuf) === :done || error("parse failed")
st.header_len = head_length(st.hbuf)

check("request build (views)", 800, () -> _build_request(st))

# Response builders

check("text response", 512, () -> text("hello"))
check("fail response", 512, () -> fail(404, "Not Found"))

exit(failed[] ? 1 : 0)
