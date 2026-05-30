#!/usr/bin/env julia
# Ciro.jl — Feature showcase server
# Run with: julia --threads=auto --project=. server.jl
using Ciro
import Ciro: intercept   # explicit import required to extend the generic function

# ══════════════════════════════════════════════════════════════════════════════
# Custom middleware (functor pattern — zero virtual dispatch)
# ══════════════════════════════════════════════════════════════════════════════

struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(ctx::Context)
    auth = header(ctx, "Authorization")
    auth == "Bearer $(m.token)" || return fail(401, "Unauthorized")
    return m.handler(ctx)
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

function handle_root(ctx::Context)
    text("Hello from Ciro.jl!")
end

function handle_json(ctx::Context)
    json("""{"framework":"Ciro.jl","status":"ok","version":"0.1.0"}""")
end

function handle_html(ctx::Context)
    html("""
    <!DOCTYPE html>
    <html><head><title>Ciro.jl</title></head>
    <body><h1>Ciro.jl</h1><p>High-performance Julia web framework.</p></body>
    </html>
    """)
end

function handle_redirect(ctx::Context)
    redirect("/")
end

# — Route parameters (typed) ──────────────────────────────────────────────────

function handle_user(ctx::Context)
    id = param(ctx, Int, :id)
    id === nothing && return fail(400, "id must be an integer")
    json("""{"user_id":$id,"name":"User $id"}""")
end

function handle_post_comment(ctx::Context)
    post_id    = param(ctx, Int, :post_id)
    comment_id = param(ctx, Int, :comment_id)
    json("""{"post":$post_id,"comment":$comment_id}""")
end

# — Wildcard routes ───────────────────────────────────────────────────────────

function handle_files(ctx::Context)
    text("Serving: $(path(ctx))")
end

# — Request body ──────────────────────────────────────────────────────────────

function handle_echo(ctx::Context)
    ct      = content_type(ctx)
    payload = body(ctx)
    isempty(payload) && return fail(400, "Empty body")
    text("Echo [$ct]: $payload")
end

function handle_upload(ctx::Context)
    raw = rawbody(ctx)
    text("Received $(length(raw)) bytes")
end

# — Query parameters ──────────────────────────────────────────────────────────

function handle_search(ctx::Context)
    qp   = queryparams(ctx)
    q    = get(qp, "q", "")
    page = get(qp, "page", "1")
    isempty(q) && return fail(400, "Missing query param: q")
    json("""{"query":"$q","page":$page,"results":[]}""")
end

# — Cookies ───────────────────────────────────────────────────────────────────

function handle_set_cookie(ctx::Context)
    resp = text("Cookie set!")
    push!(resp.headers, setcookie("session", "abc123"; max_age=3600, httponly=true))
    return resp
end

function handle_read_cookie(ctx::Context)
    sess        = cookie(ctx, "session", "none")
    all_cookies = cookies(ctx)
    json("""{"session":"$sess","total_cookies":$(length(all_cookies))}""")
end

# — Headers ───────────────────────────────────────────────────────────────────

function handle_headers(ctx::Context)
    ua     = header(ctx, "User-Agent", "unknown")
    accept = header(ctx, "Accept", "*/*")
    json("""{"user_agent":"$ua","accept":"$accept"}""")
end

# — Protected (custom middleware) ─────────────────────────────────────────────

function handle_secret(ctx::Context)
    json("""{"message":"Access granted","user":"authenticated"}""")
end

# — Error triggering ────────────────────────────────────────────────────────────────────

function handle_panic(ctx::Context)
    error("deliberate error — caught by AppCatcher")
end

# ══════════════════════════════════════════════════════════════════════════════
# Middleware stack (compose outermost → innermost)
# ══════════════════════════════════════════════════════════════════════════════
#
# Request flows:  WithRateLimit → WithSecurityHeaders → WithCORS → WithRequestId
#                  → WithTiming → WithLogger → handler
#
# Applied at registration time: Julia monomorphizes the entire chain per route
# into a single inlined call with no virtual dispatch.

const _stack = handler -> WithRateLimit(
    WithSecurityHeaders(
        WithCORS(
            WithRequestId(
                WithTiming(
                    WithLogger(handler)
                )
            )
        )
    )
)

# ══════════════════════════════════════════════════════════════════════════════
# Router
# ══════════════════════════════════════════════════════════════════════════════

router = Trie()

# Static routes
get!(router, "/",        _stack(handle_root))
get!(router, "/json",    _stack(handle_json))
get!(router, "/html",    _stack(handle_html))
get!(router, "/redir",   _stack(handle_redirect))
get!(router, "/headers", _stack(handle_headers))

# Route groups — /api/v1 namespace
group!(router, "/api/v1") do g
    get!(g, "/search",  _stack(handle_search))
    post!(g, "/echo",   _stack(handle_echo))
    post!(g, "/upload", _stack(handle_upload))

    # Untyped param → handler validates → 400 on bad input
    get!(g, "/users/:id", _stack(handle_user))
    # Typed params → router rejects non-integers → 404 (route constraint)
    get!(g, "/posts/:post_id::Int/comments/:comment_id::Int", _stack(handle_post_comment))

    # Cookies
    get!(g, "/set-cookie",  _stack(handle_set_cookie))
    get!(g, "/read-cookie", _stack(handle_read_cookie))

    # Protected with custom middleware (WithAuth sits inside the global stack)
    get!(g, "/secret", _stack(WithAuth(handle_secret, "supersecret")))

    # Error handling demonstration
    get!(g, "/panic",  _stack(handle_panic))
end

# Wildcard — must be registered on the trie directly (not inside a group)
get!(router, "/files/*", _stack(handle_files))

# HEAD is auto-generated from GET (RFC 9110 §9.3.2) — no explicit registration needed

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
    GET  /api/v1/users/42               → Typed param, parsed in handler
    GET  /api/v1/users/abc              → 400 (handler rejects non-integer)
    GET  /api/v1/posts/1/comments/5     → Multi typed params (:Int constraint, 404 on mismatch)
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
