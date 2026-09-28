#!/usr/bin/env julia
# ══════════════════════════════════════════════════════════════════════════════
# Ciro.jl — real-world example: real-time AI chat rooms
#
# Multiple browser tabs chat live over SSE; an assistant answers after
# simulated inference on the async executor. Exercises fan-out streaming,
# async handlers, chunked transcript downloads, uploads with Expect:
# 100-continue, per-route limits, typed params, middleware, telemetry, the
# copy-on-escape rule, and overload shedding (the "Flood" button).
#
# Run:
#   julia --project=. --threads=8 examples/ai_chat/server.jl
#
# Configuration (environment variables):
#   CIRO_PORT=8080  CIRO_BACKEND=uring|sockets  CIRO_WORKERS=<threads>
#   CIRO_THINK_MS=400  CIRO_ADMIN_TOKEN=demo-token  CIRO_WORKERS_MAX=32
# ══════════════════════════════════════════════════════════════════════════════

using Ciro
using Dates

import Ciro: telemetry_capture_path, telemetry_request!, telemetry_response!,
             telemetry_read!, telemetry_exception!

# ── Domain state ────────────────────────────────────────────────────────────

struct Message
    id     :: Int
    author :: String
    kind   :: Symbol          # :user | :assistant | :system
    text   :: String
    at     :: Float64
end

"""One SSE subscriber: an unbounded channel plus a queue-depth counter, so
broadcast never blocks and a stalled client is dropped instead of buffered."""
mutable struct Subscriber
    ch      :: Channel{String}
    pending :: Threads.Atomic{Int}
end

Subscriber() = Subscriber(Channel{String}(Inf), Threads.Atomic{Int}(0))

const SUB_QUEUE_MAX = 64

mutable struct ChatRoom
    id       :: Int
    name     :: String
    messages :: Vector{Message}
    subs     :: Vector{Subscriber}
end

mutable struct ChatState
    lock     :: ReentrantLock
    rooms    :: Vector{ChatRoom}
    next_id  :: Int
    max_msgs :: Int
end

ChatState() = ChatState(ReentrantLock(),
                        [ChatRoom(1, "general", Message[], Subscriber[]),
                         ChatRoom(2, "ml",      Message[], Subscriber[]),
                         ChatRoom(3, "loadtest", Message[], Subscriber[])],
                        0, 200)

const SERVICE = (name = "mock-assistant", version = "0.1.0")

json_escape(s::AbstractString) = sprint() do io
    for c in s
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        else
            print(io, c)
        end
    end
end

message_json(m::Message) =
    "{\"id\":$(m.id),\"author\":\"$(json_escape(m.author))\"," *
    "\"kind\":\"$(m.kind)\",\"text\":\"$(json_escape(m.text))\"," *
    "\"at\":$(round(m.at; digits = 3))}"

message_frame(m::Message) = "event: message\ndata: $(message_json(m))\n\n"
typing_frame(author::AbstractString) =
    "event: typing\ndata: {\"author\":\"$(json_escape(author))\"}\n\n"

function presence_frame(state::ChatState, room_id::Int)
    n = lock(state.lock) do
        length(state.rooms[room_id].subs)
    end
    return "event: presence\ndata: {\"room\":$room_id,\"users\":$n}\n\n"
end

function rooms_json(state::ChatState)
    return lock(state.lock) do
        "{\"rooms\":[" * join((
            "{\"id\":$(r.id),\"name\":\"$(r.name)\"," *
            "\"messages\":$(length(r.messages)),\"subscribers\":$(length(r.subs))}"
            for r in state.rooms), ",") * "]}"
    end
end

function messages_json(state::ChatState, room_id::Int)
    return lock(state.lock) do
        room = state.rooms[room_id]
        first_idx = max(1, length(room.messages) - 49)
        recent = room.messages[first_idx:end]
        "{\"messages\":[" * join((message_json(m) for m in recent), ",") * "]}"
    end
end

function transcript_lines(state::ChatState, room_id::Int)
    return lock(state.lock) do
        room = state.rooms[room_id]
        [string(Dates.format(Dates.unix2datetime(m.at), "HH:MM:SS"), " ",
                m.author, ": ", m.text) for m in room.messages]
    end
end

"""Store a message (capped history) and return it, or `nothing` for a bad room."""
function store_message!(state::ChatState, room_id::Int, author::String,
                        text::String, kind::Symbol)
    return lock(state.lock) do
        (1 <= room_id <= length(state.rooms)) || return nothing
        room = state.rooms[room_id]
        state.next_id += 1
        msg = Message(state.next_id, author, kind, text, time())
        push!(room.messages, msg)
        length(room.messages) > state.max_msgs && popfirst!(room.messages)
        return msg
    end
end

function add_subscriber!(state::ChatState, room_id::Int)::Subscriber
    sub = Subscriber()
    lock(state.lock) do
        push!(state.rooms[room_id].subs, sub)
    end
    return sub
end

function remove_subscriber!(state::ChatState, room_id::Int, sub::Subscriber)
    return lock(state.lock) do
        filter!(s -> s !== sub, state.rooms[room_id].subs)
        length(state.rooms[room_id].subs)
    end
end

"""Fan-out one frame to a room. Broadcast never blocks; a subscriber whose
queue passed `SUB_QUEUE_MAX` is dropped (its SSE loop then ends)."""
function broadcast!(state::ChatState, room_id::Int, frame::String)
    lock(state.lock) do
        for sub in state.rooms[room_id].subs
            isopen(sub.ch) || continue
            if Threads.atomic_add!(sub.pending, 1) + 1 > SUB_QUEUE_MAX
                Threads.atomic_sub!(sub.pending, 1)
                close(sub.ch)                       # slow client: disconnect
            else
                try
                    put!(sub.ch, frame)             # unbounded: never blocks
                catch
                    Threads.atomic_sub!(sub.pending, 1)
                end
            end
        end
    end
    return nothing
end

# ── Assistant (simulated inference) ─────────────────────────────────────────

function assistant_reply(text::String)::String
    t = lowercase(strip(text))
    occursin("hello", t) || occursin("hi", t) ? "Hey! How can I help?" :
    endswith(t, "?") ? "Good question — I'm a mock model, but the pipeline " *
                       "(async worker → SSE broadcast) is real." :
    "You said: \"$text\". Here's a mock answer from $(SERVICE.name)."
end

# ── Middleware ──────────────────────────────────────────────────────────────

struct RequireToken{H}
    token   :: String
    handler :: H
end

function (m::RequireToken)(ctx::Context)
    header(ctx, "X-Admin-Token") == m.token || return fail(401, "Unauthorized")
    return m.handler(ctx)
end

# ── Static files (traversal-guarded wildcard) ───────────────────────────────

const PUBLIC_DIR = joinpath(@__DIR__, "public")

function serve_static(ctx::Context)
    target = String(path(ctx))
    rel = startswith(target, "/static/") ? target[9:end] : ""
    (isempty(rel) || startswith(rel, '/') || occursin("..", rel)) &&
        return fail(404, "Not Found")
    file = joinpath(PUBLIC_DIR, rel)
    isfile(file) || return fail(404, "Not Found")
    ctype = endswith(rel, ".html") ? "text/html; charset=utf-8" :
            endswith(rel, ".js")   ? "application/javascript; charset=utf-8" :
            endswith(rel, ".css")  ? "text/css; charset=utf-8" :
            endswith(rel, ".svg")  ? "image/svg+xml" : "application/octet-stream"
    return Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-cache"],
                    read(file))
end

# ── Handlers ────────────────────────────────────────────────────────────────

_user(ctx::Context)::String = begin
    name = strip(get(queryparams(ctx), "as", "anon"))
    isempty(name) ? "anon" : String(first(name, 32))
end

_valid_room(state::ChatState, id::Int) = 1 <= id <= length(state.rooms)

function post_message(ctx::Context, state::ChatState, think_s::Float64)
    room_id = param(ctx, Int, :id)
    _valid_room(state, room_id) || return fail(404, "Unknown room")
    text = String(strip(body(ctx)))
    isempty(text) && return fail(422, "Empty message")

    user = _user(ctx)
    msg = store_message!(state, room_id, user, text, :user)
    broadcast!(state, room_id, message_frame(msg))

    # Retention rule: copy the request before handing it to another task.
    saved = copy(ctx)
    Threads.@spawn begin
        sleep(0.05)
        println("[audit] room=$room_id user=$(user) " *
                "bytes=$(ncodeunits(text)) path=$(saved.request.path)")
    end

    # Simulated inference on the async worker; everyone sees it live via SSE.
    broadcast!(state, room_id, typing_frame(SERVICE.name))
    sleep(think_s)
    reply = store_message!(state, room_id, SERVICE.name, assistant_reply(text), :assistant)
    broadcast!(state, room_id, message_frame(reply))

    return json("{\"message\":$(message_json(msg)),\"reply\":$(message_json(reply))}")
end

function events_handler(ctx::Context, state::ChatState)
    room_id = param(ctx, Int, :id)
    _valid_room(state, room_id) || return fail(404, "Unknown room")

    return sse() do send
        sub = add_subscriber!(state, room_id)
        ch = sub.ch
        broadcast!(state, room_id, presence_frame(state, room_id))
        try
            while isopen(ch)
                frame = if timedwait(() -> isready(ch), 15.0) == :ok
                    f = take!(ch)
                    Threads.atomic_sub!(sub.pending, 1)
                    f
                else
                    ": keepalive\n\n"
                end
                send(frame)
            end
        catch err
            err isa StreamClosedError || rethrow(err)
        finally
            remove_subscriber!(state, room_id, sub)
            close(ch)
            broadcast!(state, room_id, presence_frame(state, room_id))
        end
    end
end

function transcript_handler(ctx::Context, state::ChatState)
    room_id = param(ctx, Int, :id)
    _valid_room(state, room_id) || return fail(404, "Unknown room")
    lines = transcript_lines(state, room_id)
    return stream() do w
        println(w, "# transcript · room $(room_id) · $(length(lines)) messages")
        for line in lines
            println(w, line)
            sleep(0.02)                 # show incremental chunk delivery
        end
    end
end

function import_handler(ctx::Context, state::ChatState)
    room_id = param(ctx, Int, :id)
    _valid_room(state, room_id) || return fail(404, "Unknown room")
    lines = countlines(IOBuffer(body(ctx)))
    msg = store_message!(state, room_id, "system", "imported $lines lines", :system)
    broadcast!(state, room_id, message_frame(msg))
    return json("{\"imported\":$lines}")
end

# ── Application ─────────────────────────────────────────────────────────────

"""
    build_chat(; port, backend, nworkers, admin_token, think_s, ...) -> Server

Build (but do not start) the chat server. Kept separate from `main` so tests
can start it in-process with a small worker pool.
"""
function build_chat(;
    port::Int = 8080,
    backend::Symbol = :uring,
    nworkers::Int = Threads.nthreads(),
    admin_token::String = "demo-token",
    think_s::Float64 = 0.4,
    worker_threads::Int = 32,
    max_pending::Int = 64,
    catcher::AbstractCatcher = DefaultCatcher(),
)
    state = ChatState()
    telemetry = ServerMetrics()
    router = Trie()

    # Chat SPA and assets
    get!(router, "/", _ -> html(read(joinpath(PUBLIC_DIR, "index.html"), String)))
    get!(router, "/static/*", serve_static)

    # Rooms and history
    get!(router, "/api/v1/rooms", _ -> json(rooms_json(state)))
    get!(router, "/api/v1/rooms/:id::Int/messages", ctx -> begin
        room_id = param(ctx, Int, :id)
        _valid_room(state, room_id) || return fail(404, "Unknown room")
        return json(messages_json(state, room_id))
    end)

    # Post a message: stored/broadcast immediately, assistant reply after
    # simulated inference (the handler runs on the async executor).
    post!(router, "/api/v1/rooms/:id::Int/messages",
          ctx -> post_message(ctx, state, think_s);
          limits = RouteLimits(max_body_size = 4096))

    # Live room events (SSE fan-out) and chunked transcript download
    get!(router, "/api/v1/rooms/:id::Int/events", ctx -> events_handler(ctx, state))
    get!(router, "/api/v1/rooms/:id::Int/transcript", ctx -> transcript_handler(ctx, state))

    # Import a transcript file (8 KB route limit; curl sends Expect for big ones)
    post!(router, "/api/v1/rooms/:id::Int/import",
          ctx -> import_handler(ctx, state);
          limits = RouteLimits(max_body_size = 8192))

    # Metrics for the UI, admin stats behind a token
    get!(router, "/api/metrics", _ -> json(_metrics_json(telemetry)))
    get!(router, "/admin/stats", RequireToken(admin_token, _ -> begin
        s = metrics_snapshot(telemetry)
        rooms = lock(state.lock) do
            join(("\"$(r.name)\":{\"messages\":$(length(r.messages))," *
                  "\"subscribers\":$(length(r.subs))}" for r in state.rooms), ",")
        end
        return json("{\"requests\":$(s.requests),\"responses\":$(s.responses)," *
                    "\"status_4xx\":$(s.status_4xx),\"status_5xx\":$(s.status_5xx)," *
                    "\"rooms\":{$rooms}}")
    end))

    return Server(; router, port, backend, telemetry, catcher,
                  executor = AsyncExecutor(worker_threads = worker_threads,
                                           max_pending = max_pending),
                  max_body_size = 1_048_576,
                  idle_timeout_ms = 120_000)
end

function _metrics_json(m::ServerMetrics)
    s = metrics_snapshot(m)
    return string("{\"requests\":", s.requests,
                  ",\"responses\":", s.responses,
                  ",\"status_2xx\":", s.status_2xx,
                  ",\"status_4xx\":", s.status_4xx,
                  ",\"status_5xx\":", s.status_5xx,
                  ",\"bytes_in\":", s.bytes_in,
                  ",\"bytes_out\":", s.bytes_out, "}")
end

# ── Environment configuration ───────────────────────────────────────────────

function _env_int(key::String, default::Int)::Int
    raw = get(ENV, key, "")
    isempty(raw) && return default
    value = tryparse(Int, raw)
    value === nothing && error("$key must be an integer, got $(repr(raw))")
    return value
end

function main()
    # Positional args override the environment: `server.jl [port] [backend]`.
    port        = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : _env_int("CIRO_PORT", 8080)
    backend     = length(ARGS) >= 2 ? Symbol(ARGS[2]) :
                  Symbol(get(ENV, "CIRO_BACKEND", "uring"))
    nworkers    = _env_int("CIRO_WORKERS", Threads.nthreads())
    think_ms    = _env_int("CIRO_THINK_MS", 400)
    admin_token = get(ENV, "CIRO_ADMIN_TOKEN", "demo-token")
    workers_max = _env_int("CIRO_WORKERS_MAX", 32)

    server = build_chat(; port, backend, nworkers, admin_token,
                        think_s = think_ms / 1000, worker_threads = workers_max,
                        max_pending = 2 * workers_max)

    println("""
    Ciro.jl AI chat
      http://localhost:$port   backend=:$backend   workers=$nworkers
      assistant pool: $workers_max workers (each open SSE stream holds one)
      open two tabs to see live fan-out.

      GET  /api/v1/rooms/:id/messages        POST /api/v1/rooms/:id/messages?as=you
      GET  /api/v1/rooms/:id/events (SSE)    GET  /api/v1/rooms/:id/transcript
      POST /api/v1/rooms/:id/import          GET  /admin/stats (X-Admin-Token)

      token: $admin_token   ·   stop: Ctrl-C (graceful drain)
    """)
    start!(server; nworkers)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
