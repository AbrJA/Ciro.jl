#!/usr/bin/env julia
# Ciro.jl — Feature showcase server
# Run with: julia --threads=auto --project=. server.jl
using Ciro

# ══════════════════════════════════════════════════════════════════════════════
# Custom middleware (functor pattern — zero virtual dispatch)
# ══════════════════════════════════════════════════════════════════════════════

struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(req)
    auth = header(req, "Authorization")
    auth == "Bearer $(m.token)" || return fail(401, "Unauthorized")
    return m.handler(req)
end

# ══════════════════════════════════════════════════════════════════════════════
# Custom error catcher
# ══════════════════════════════════════════════════════════════════════════════

struct AppCatcher <: AbstractCatcher end

function intercept(::AppCatcher, err::Exception, req)
    @error "Unhandled $(typeof(err))" exception=err
    return json("""{"error":"internal_error","message":"Something went wrong"}"""; status=500)
end

# ══════════════════════════════════════════════════════════════════════════════
# Handlers
# ══════════════════════════════════════════════════════════════════════════════

# — Static routes ─────────────────────────────────────────────────────────────

function handle_root(req)
    text("Hello from Ciro.jl!")
end

function handle_json(req)
    json("""{"framework":"Ciro.jl","status":"ok","version":"0.1.0"}""")
end

function handle_html(req)
    html("""
    <!DOCTYPE html>
    <html><head><title>Ciro.jl</title></head>
    <body><h1>Ciro.jl</h1><p>High-performance Julia web framework.</p></body>
    </html>
    """)
end

function handle_redirect(req)
    redirect("/")
end

# — Route parameters (typed) ──────────────────────────────────────────────────

function handle_user(req)
    id = param(Int, :id)
    id === nothing && return fail(400, "id must be an integer")
    json("""{"user_id":$id,"name":"User $id"}""")
end

function handle_post_comment(req)
    post_id = param(Int, :post_id)
    comment_id = param(Int, :comment_id)
    json("""{"post":$post_id,"comment":$comment_id}""")
end

# — Wildcard routes ───────────────────────────────────────────────────────────

function handle_files(req)
    text("Serving: $(path(req))")
end

# — Request body ──────────────────────────────────────────────────────────────

function handle_echo(req)
    ct = content_type(req)
    payload = body(req)
    isempty(payload) && return fail(400, "Empty body")
    text("Echo [$ct]: $payload")
end

function handle_upload(req)
    raw = rawbody(req)
    text("Received $(length(raw)) bytes")
end

# — Query parameters ──────────────────────────────────────────────────────────

function handle_search(req)
    qp = queryparams(req)
    q = get(qp, "q", "")
    page = get(qp, "page", "1")
    isempty(q) && return fail(400, "Missing query param: q")
    json("""{"query":"$q","page":$page,"results":[]}""")
end

# — Cookies ───────────────────────────────────────────────────────────────────

function handle_set_cookie(req)
    resp = text("Cookie set!")
    push!(resp.headers, setcookie("session", "abc123"; max_age=3600, httponly=true))
    return resp
end

function handle_read_cookie(req)
    sess = cookie(req, "session", "none")
    all_cookies = cookies(req)
    json("""{"session":"$sess","total_cookies":$(length(all_cookies))}""")
end

# — Headers ───────────────────────────────────────────────────────────────────

function handle_headers(req)
    ua = header(req, "User-Agent", "unknown")
    accept = header(req, "Accept", "*/*")
    json("""{"user_agent":"$ua","accept":"$accept"}""")
end

# — Protected (custom middleware) ─────────────────────────────────────────────

function handle_secret(req)
    json("""{"message":"Access granted","user":"authenticated"}""")
end

# — Error triggering ──────────────────────────────────────────────────────────

function handle_panic(req)
    error("deliberate error — caught by AppCatcher")
end

# ══════════════════════════════════════════════════════════════════════════════
# Router
# ══════════════════════════════════════════════════════════════════════════════

router = Trie()

# Static routes
get!(router, "/",        handle_root)
get!(router, "/json",    handle_json)
get!(router, "/html",    handle_html)
get!(router, "/redir",   handle_redirect)
get!(router, "/headers", handle_headers)

# Route groups — /api/v1 namespace
group!(router, "/api/v1") do g
    get!(g, "/search",                           handle_search)
    post!(g, "/echo",                            handle_echo)
    post!(g, "/upload",                          handle_upload)

    # Typed integer params  (:id::Int rejects non-integers at the router level)
    get!(g, "/users/:id::Int",                   handle_user)
    get!(g, "/posts/:post_id::Int/comments/:comment_id::Int", handle_post_comment)

    # Cookies
    get!(g, "/set-cookie",                       handle_set_cookie)
    get!(g, "/read-cookie",                      handle_read_cookie)

    # Protected with custom middleware
    get!(g, "/secret",  WithAuth(handle_secret, "supersecret"))

    # Error handling demonstration
    get!(g, "/panic",   handle_panic)
end

# Wildcard — must be registered on the trie directly (not inside a group)
get!(router, "/files/*", handle_files)

# HEAD is auto-generated from GET (RFC 9110 §9.3.2) — no explicit registration needed

# ══════════════════════════════════════════════════════════════════════════════
# Middleware stack (compose outermost → innermost)
# ══════════════════════════════════════════════════════════════════════════════
#
# Request flows:  WithRateLimit → WithSecurityHeaders → WithCORS → WithRequestId
#                  → WithTiming → WithLogger → router dispatch
#
# Each layer is a generic struct — the compiler monomorphizes the entire chain
# into a single inlined function with no virtual dispatch.

# ══════════════════════════════════════════════════════════════════════════════
# Server
# ══════════════════════════════════════════════════════════════════════════════

server = Server(;
    router,
    catcher  = AppCatcher(),
    port     = 3001,
    host     = "0.0.0.0",
    max_body_size = 4 * 1_048_576,  # 4 MiB
    shutdown_timeout = 10.0,
)

println("""
Ciro.jl feature showcase — http://localhost:3001

  Static routes:
    GET  /                         → Hello plaintext
    GET  /json                     → JSON response
    GET  /html                     → HTML response
    GET  /redir                    → Redirect to /
    GET  /headers                  → Echo request headers

  Route groups (/api/v1):
    GET  /api/v1/search?q=foo&page=2     → Query params
    POST /api/v1/echo                    → Echo body (Content-Type preserved)
    POST /api/v1/upload                  → Raw bytes upload
    GET  /api/v1/users/42               → Typed param :id::Int
    GET  /api/v1/users/abc              → 404 (Int validation fails)
    GET  /api/v1/posts/1/comments/5     → Multi typed params
    GET  /api/v1/set-cookie             → Set session cookie
    GET  /api/v1/read-cookie            → Read session cookie
    GET  /api/v1/secret                 → 401 without Bearer token
    GET  /api/v1/panic                  → 500 via AppCatcher (JSON error)

  Wildcard:
    GET  /files/any/path/here           → Wildcard catch-all

  HEAD auto-generation:
    HEAD /                              → 200, no body (from GET handler)

  Middleware applied globally (outermost → innermost):
    WithRateLimit     — 100 req/min per IP (token bucket)
    WithSecurityHeaders — HSTS, CSP, X-Frame-Options, nosniff
    WithCORS          — Access-Control-Allow-Origin: *
    WithRequestId     — X-Request-Id
    WithTiming        — X-Response-Time
    WithLogger        — stdout access log
""")

start!(server)
