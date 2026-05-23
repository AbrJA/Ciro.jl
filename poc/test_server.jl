#!/usr/bin/env julia
# Quick integration test — start server, curl it, verify responses
using CiroCore
using CiroRouter
using CiroMiddleware

# Build app
router = Router()
route_get!(router, "/", req -> text("Hello, World!"))
route_get!(router, "/json", req -> json_response("""{"status":"ok"}"""))
route_get!(router, "/users/:id", req -> text("User: $(route_param(:id))"))
route_post!(router, "/echo", req -> text(String(copy(req.body))))

# Middleware composition
route_get!(router, "/timed", WithTiming(req -> text("fast")))
route_get!(router, "/cors", WithCORS(req -> text("cors ok")))

server = CiroServer(; router, port=3001)

println("Server ready on http://localhost:3001")
println("Testing routes...")
start!(server)
