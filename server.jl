#!/usr/bin/env julia
# Quick integration test — start server, curl it, verify responses
using Ciro

# Build app
trie = Trie()
get!(trie, "/", req -> text("Hello, World!"))
get!(trie, "/json", req -> json_response("""{"status":"ok"}"""))
get!(trie, "/users/:id", req -> text("User: $(param(:id))"))
post!(trie, "/echo", req -> text(String(copy(req.body))))

# Middleware composition
get!(trie, "/timed", WithTiming(req -> text("fast")))
get!(trie, "/cors", WithCORS(req -> text("cors ok")))

server = Server(; router=trie, port=3001)

println("Server ready on http://localhost:3001")
println("Testing routes...")
start!(server)
