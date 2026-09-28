#!/usr/bin/env julia
# Ciro.jl — Feature showcase server
# Demonstrates every routing and request feature available in the core.
# Middleware and cookies are in separate packages — not used here.
#
# Run with: julia --threads=auto --project=. examples_server.jl
# Test with: curl http://localhost:3001/
using Ciro

# ── Custom middleware (functor pattern — zero virtual dispatch) ───────────────
# Middleware lives outside core. Here we show the pattern directly so you can
# see how to write one without importing an extension package.

struct WithAuth{H}
    handler :: H
    token   :: String
end

function (m::WithAuth)(ctx::Context)
    auth = header(ctx, "Authorization")
    auth == "Bearer $(m.token)" || return fail(401, "Unauthorized")
    return m.handler(ctx)
end

# ── Custom error catcher ─────────────────────────────────────────────────────

struct AppCatcher <: AbstractCatcher end

# Extend Ciro.Interface.intercept — the module is named Interface (singular).
function Ciro.Interface.intercept(::AppCatcher, err::Exception, _)
    @error "Unhandled $(typeof(err))" exception=err
    return json("""{"error":"internal_error","message":"Something went wrong"}"""; status=500)
end

# ══════════════════════════════════════════════════════════════════════════════
# Handlers
# ══════════════════════════════════════════════════════════════════════════════

function handle_root(ctx::Context)
    text("Hello from Ciro.jl!")
end

function handle_json(ctx::Context)
    json("""{"framework":"Ciro.jl","status":"ok","version":"0.1.0"}""")
end

function handle_html(ctx::Context)
    html("""<!DOCTYPE html>
<html><head><title>Ciro.jl</title></head>
<body><h1>Ciro.jl</h1><p>High-performance Julia web framework.</p></body>
</html>""")
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

# — Wildcard ──────────────────────────────────────────────────────────────────

function handle_files(ctx::Context)
    text("Serving: $(path(ctx))")
end

# — Body ──────────────────────────────────────────────────────────────────────

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

# — Error handling ────────────────────────────────────────────────────────────

function handle_panic(ctx::Context)
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

# Route groups
group!(router, "/api/v1") do g
    get!(g, "/search",  handle_search)
    post!(g, "/echo",   handle_echo)
    post!(g, "/upload", handle_upload)

    # Untyped param — handler validates, returns 400 on bad input
    get!(g, "/users/:id", handle_user)

    # Typed params — router rejects mismatches at dispatch (404, never calls handler)
    get!(g, "/posts/:post_id::Int/comments/:comment_id::Int", handle_post_comment)

    # Protected with per-handler middleware (no global stack needed)
    get!(g, "/secret", WithAuth(handle_secret, "supersecret"))

    get!(g, "/panic", handle_panic)
end

# Wildcard — registered at top level, not inside a group
get!(router, "/files/*", handle_files)

# ══════════════════════════════════════════════════════════════════════════════
# Server
# ══════════════════════════════════════════════════════════════════════════════

server = Server(;
    router,
    catcher  = AppCatcher(),
    port     = 3001,
    host     = "0.0.0.0",
    max_body_size    = 4 * 1_048_576,  # 4 MiB
    shutdown_timeout = 10.0,
)

println("""
Ciro.jl feature showcase — http://localhost:3001

  GET  /                              → Hello plaintext
  GET  /json                          → JSON response
  GET  /html                          → HTML response
  GET  /redir                         → Redirect to /
  GET  /headers                       → Echo request headers

  GET  /api/v1/search?q=foo&page=2    → Query params
  POST /api/v1/echo                   → Echo body
  POST /api/v1/upload                 → Raw bytes upload
  GET  /api/v1/users/42               → Typed param, parsed in handler
  GET  /api/v1/users/abc              → 400 (handler rejects non-integer)
  GET  /api/v1/posts/1/comments/5     → Multi typed params (Int constraint)
  GET  /api/v1/secret                 → 401 without: Authorization: Bearer supersecret
  GET  /api/v1/panic                  → 500 via AppCatcher (JSON error)

  GET  /files/any/path/here           → Wildcard catch-all
  HEAD /                              → 200, no body (auto-generated from GET)
""")

start!(server)
