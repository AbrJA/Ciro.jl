module RouterTests
using Test

include(joinpath(@__DIR__, "../src/Ciro.jl"))
using .Ciro.Routers
using .Ciro.Tries
using .Ciro.Types

@testset "Router HTTP Methods" begin
    router = Router(RouterTrie(), Function[])

    handler_get() = "get"
    handler_post() = "post"
    handler_put() = "put"
    handler_delete() = "delete"
    handler_patch() = "patch"
    handler_options() = "options"
    handler_head() = "head"

    # Test all HTTP method insertions
    Tries.insert!(router.trie, "GET", "/test", handler_get)
    Tries.insert!(router.trie, "POST", "/test", handler_post)
    Tries.insert!(router.trie, "PUT", "/test", handler_put)
    Tries.insert!(router.trie, "DELETE", "/test", handler_delete)
    Tries.insert!(router.trie, "PATCH", "/test", handler_patch)
    Tries.insert!(router.trie, "OPTIONS", "/test", handler_options)
    Tries.insert!(router.trie, "HEAD", "/test", handler_head)

    # Verify each method resolves correctly
    h, _ = Tries.lookup(router.trie, "GET", "/test")
    @test h == handler_get

    h, _ = Tries.lookup(router.trie, "POST", "/test")
    @test h == handler_post

    h, _ = Tries.lookup(router.trie, "PUT", "/test")
    @test h == handler_put

    h, _ = Tries.lookup(router.trie, "DELETE", "/test")
    @test h == handler_delete

    h, _ = Tries.lookup(router.trie, "PATCH", "/test")
    @test h == handler_patch

    h, _ = Tries.lookup(router.trie, "OPTIONS", "/test")
    @test h == handler_options

    h, _ = Tries.lookup(router.trie, "HEAD", "/test")
    @test h == handler_head
end

@testset "lookup! with Pre-allocated Params" begin
    router = RouterTrie()

    handler() = "handler"
    Tries.insert!(router, "GET", "/users/:id/posts/:post_id", handler)

    # Test with pre-allocated dict
    params = Dict{String,String}()
    h, p = Tries.lookup!(router, "GET", "/users/123/posts/456", params)

    @test h == handler
    @test p["id"] == "123"
    @test p["post_id"] == "456"
    @test p === params  # Same dict instance (no allocation)

    # Reuse the dict
    empty!(params)
    h, p = Tries.lookup!(router, "GET", "/users/789/posts/101", params)
    @test p["id"] == "789"
    @test p["post_id"] == "101"
end

end # module
