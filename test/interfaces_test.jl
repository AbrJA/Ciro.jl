using Test
using CiroInterfaces

@testset "CiroInterfaces" begin

    @testset "Methods" begin
        @test Methods.from_string("GET") == Methods.GET
        @test Methods.from_string("POST") == Methods.POST
        @test Methods.from_string("PUT") == Methods.PUT
        @test Methods.from_string("DELETE") == Methods.DELETE
        @test Methods.from_string("PATCH") == Methods.PATCH
        @test Methods.from_string("HEAD") == Methods.HEAD
        @test Methods.from_string("OPTIONS") == Methods.OPTIONS
        @test Methods.from_string("INVALID") == Methods.UNKNOWN
        @test Methods.from_string("") == Methods.UNKNOWN

        @test Methods.to_string(Methods.GET) == "GET"
        @test Methods.to_string(Methods.POST) == "POST"
        @test Methods.to_string(Methods.UNKNOWN) == "UNKNOWN"
    end

    @testset "Response builders" begin
        r = text("hello")
        @test r.status == 200
        @test String(copy(r.body)) == "hello"
        @test any(p -> p.first == "Content-Type" && contains(p.second, "text/plain"), r.headers)

        r = text("error"; status=500)
        @test r.status == 500

        r = html("<h1>Hi</h1>")
        @test r.status == 200
        @test any(p -> contains(p.second, "text/html"), r.headers)

        r = json_response("""{"ok":true}""")
        @test r.status == 200
        @test any(p -> contains(p.second, "application/json"), r.headers)
        @test String(copy(r.body)) == """{"ok":true}"""

        r = json_response("""{"ok":true}"""; status=201)
        @test r.status == 201

        r = redirect("/login")
        @test r.status == 302
        @test any(p -> p.first == "Location" && p.second == "/login", r.headers)

        r = redirect("/new"; status=301)
        @test r.status == 301

        r = error_response(404, "Not Found")
        @test r.status == 404
        @test String(copy(r.body)) == "Not Found"

        r = error_response(500)
        @test r.status == 500
        @test isempty(r.body)
    end

    @testset "Response utilities" begin
        r = Response(200, ["Content-Type" => "text/plain", "X-Custom" => "val"], UInt8[])
        @test hasheader(r, "Content-Type")
        @test !hasheader(r, "X-Missing")
        @test getheader(r, "X-Custom") == "val"
        @test getheader(r, "X-Missing", "default") == "default"
    end

    @testset "Status lines" begin
        @test status_line(200) == "HTTP/1.1 200 OK\r\n"
        @test status_line(404) == "HTTP/1.1 404 Not Found\r\n"
        @test status_line(500) == "HTTP/1.1 500 Internal Server Error\r\n"
        @test status_line(201) == "HTTP/1.1 201 Created\r\n"
        @test status_line(204) == "HTTP/1.1 204 No Content\r\n"
        # Unknown status
        @test contains(status_line(418), "HTTP/1.1 418")
    end

    @testset "Request header access" begin
        using PicoHTTPParser
        raw = Vector{UInt8}("GET /test HTTP/1.1\r\nHost: localhost\r\nX-Custom: hello\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test req_header(req, "Host") == "localhost"
        @test req_header(req, "X-Custom") == "hello"
        @test req_header(req, "Missing", "nope") == "nope"
    end

    @testset "Path/query utilities" begin
        using PicoHTTPParser
        raw = Vector{UInt8}("GET /path?foo=bar&baz=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        req = PicoHTTPParser.parse_request(raw)
        @test clean_path(req) == "/path"
        @test query_string(req) == "foo=bar&baz=1"

        raw2 = Vector{UInt8}("GET /noquery HTTP/1.1\r\nHost: x\r\n\r\n")
        req2 = PicoHTTPParser.parse_request(raw2)
        @test clean_path(req2) == "/noquery"
        @test query_string(req2) == ""
    end

    @testset "NullLogger" begin
        logger = NullLogger()
        # Should not throw
        log_event(logger, INFO, "test")
        log_event(logger, ERROR_LEVEL, "error")
    end

    @testset "DefaultErrorHandler" begin
        handler = DefaultErrorHandler()
        resp = handle_error(handler, ErrorException("secret internal info"), nothing)
        @test resp.status == 500
        # Must NOT expose internal error message (OWASP)
        body_str = String(copy(resp.body))
        @test !contains(body_str, "secret internal info")
        @test body_str == "Internal Server Error"
    end
end
