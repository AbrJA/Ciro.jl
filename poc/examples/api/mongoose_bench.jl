# Mongoose.jl benchmark server — equivalent routes to Ciro for fair comparison
using Mongoose

# Same routes as Ciro API
server = Server()

route!(server, :get, "/", req -> Response("Hello, World!")),
route!(server, :get, "/plaintext", req -> Response("Hello, World!")),
route!(server, :get, "/json", req -> Response(Json, "{\"message\":\"Hello, World!\"}")),
route!(server, :get, "/health", req -> Response(Json, "{\"status\":\"ok\"}")),
route!(server, :get, "/users/:id", req -> Response(Json, "{\"id\":$(req.params["id"]),\"name\":\"User $(req.params["id"])\",\"email\":\"user$(req.params["id"])@example.com\"}")),
route!(server, :post, "/users", req -> Response(Json, "{\"created\":true,\"data\":$(String(req.body))}"; status=201)),
route!(server, :put, "/users/:id", req -> Response(Json, "{\"updated\":true,\"id\":$(req.params["id"]),\"data\":$(String(req.body))}")),
route!(server, :delete, "/users/:id", req -> Response(""; status=204)),
route!(server, :patch, "/users/:id", req -> Response(Json, "{\"patched\":true,\"id\":$(req.params["id"])}")),
route!(server, :get, "/items", req -> Response(Json, "[{\"id\":1,\"name\":\"item1\"},{\"id\":2,\"name\":\"item2\"}]")),
route!(server, :get, "/items/:id", req -> Response(Json, "{\"id\":$(req.params["id"]),\"name\":\"item$(req.params["id"])\"}")),
route!(server, :post, "/items", req -> Response(Json, "{\"created\":true,\"item\":$(String(req.body))}"; status=201)),
route!(server, :put, "/items/:id", req -> Response(Json, "{\"updated\":true,\"id\":$(req.params["id"]),\"item\":$(String(req.body))}")),
route!(server, :delete, "/items/:id", req -> Response(""; status=204)),

println("Mongoose server starting on http://0.0.0.0:8099")
start!(server, port=8099, blocking=true)
