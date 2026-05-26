#!/usr/bin/env julia
# Ciro.jl benchmark server — mirrors khttp routes for apples-to-apples comparison
# Run with: julia --threads=auto --project=. benchmarks/ciro_bench.jl
using Ciro

# Handlers — same semantics as khttp/src/main.rs
index(req)   = text("Welcome!")
get_user(req) = text("User: $(param(:id))")
post_user(req) = text("")

router = Trie()
get!(router,  "/",          index)
get!(router,  "/user/:id",  get_user)
post!(router, "/user",      post_user)

server = Server(; router, port=8080, host="0.0.0.0")

println("Ciro.jl benchmark server listening on :8080")
println("Routes: GET /  |  GET /user/:id  |  POST /user")
start!(server)

