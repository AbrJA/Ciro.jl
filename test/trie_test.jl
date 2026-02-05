module TrieTests
using Test
using Ciro.Tries
using Ciro.Routers

@testset "Router Trie Tests" begin
    router = Router(RouterTrie(), Function[])

    handler1() = "h1"
    handler2() = "h2"
    handler3() = "h3"

    # Insert routes
    Tries.insert!(router.trie, "GET", "/users", handler1)
    Tries.insert!(router.trie, "GET", "/users/:id", handler2)
    Tries.insert!(router.trie, "POST", "/users", handler3)

    # Test Exact Match
    h, p = Tries.lookup(router.trie, "GET", "/users")
    @test h == handler1
    @test isempty(p)

    # Test Param Match
    h, p = Tries.lookup(router.trie, "GET", "/users/123")
    @test h == handler2
    @test p["id"] == "123"

    # Test Method Mismatch
    h, p = Tries.lookup(router.trie, "POST", "/users/123")
    @test h === nothing # No POST /users/:id defined

    # Test Method Match
    h, p = Tries.lookup(router.trie, "POST", "/users")
    @test h == handler3

    # Test Not Found
    h, p = Tries.lookup(router.trie, "GET", "/notfound")
    @test h === nothing
end

end
