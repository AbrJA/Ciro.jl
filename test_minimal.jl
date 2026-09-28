using Ciro

struct AppCatcher <: AbstractCatcher end
function intercept(::AppCatcher, err::Exception, req)
    @error "Unhandled" exception=err
    json("{\"error\":\"internal\"}")
end

router = Trie()
get!(router, "/", ctx -> text("Hello!"))

server = Server(; router, catcher=AppCatcher(), port=3001)
println("Starting on :3001...")
start!(server)
