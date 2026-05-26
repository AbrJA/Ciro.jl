#!/usr/bin/env julia
# Quick integration test — start server, curl it, verify responses
using Ciro

# Build app
router = Router()
get!(router, "/", req -> text("Hello, World!"))
get!(router, "/json", req -> json_response("""{"status":"ok"}"""))
get!(router, "/users/:id", req -> text("User: $(param(:id))"))
post!(router, "/echo", req -> text(String(copy(req.body))))

# Middleware composition
get!(router, "/timed", WithTiming(req -> text("fast")))
get!(router, "/cors", WithCORS(req -> text("cors ok")))

server = Server(; router, port=3001)

println("Server ready on http://localhost:3001")
println("Testing routes...")
start!(server)
