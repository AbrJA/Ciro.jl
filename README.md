# Ciro.jl ⚡

High-performance HTTP framework for Julia, built for low-latency APIs and high-concurrency ML serving on Linux.

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions)

## ✨ Why Ciro?

Ciro helps you serve models and APIs directly from Julia with a tight, type-stable runtime path.

- 🚀 io_uring backend with async I/O and zero-copy write paths
- 🧵 Thread-per-core architecture (one ring per Julia thread)
- 🧠 Type-stable hot path with minimal dispatch overhead
- 🗺️ Trie router with typed params, groups, and wildcards
- ♻️ Connection and buffer pooling to reduce steady-state allocations
- 🧩 Modular internals so components can evolve independently

## 🧰 Requirements

- Linux kernel 5.19+
- liburing development headers
- Julia 1.10+
- GCC (to build the native backend)

Ubuntu/Debian example:

```bash
sudo apt install liburing-dev
```

## 📦 Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build native backend:

```bash
cd lib && make
```

## 🚀 Quick Start

Run the included demo server:

```bash
julia --project=. -t4 server.jl
```

Smoke test:

```bash
curl http://localhost:8080/health
curl -X POST http://localhost:8080/api/v1/predict \
  -H 'Content-Type: application/json' \
  -d '{"features":[1.0,2.0,3.0]}'
```

Minimal app example:

```julia
using Ciro

function health(ctx::Context)
    json("""{"status":"healthy"}""")
end

function predict(ctx::Context)
    input = body(ctx)
    isempty(input) && return fail(400, "Empty input")
    # Replace with real parsing/model inference logic
    return json("""{"prediction":0.42}""")
end

router = Trie()
get!(router, "/health", health)
post!(router, "/predict", predict)

server = Server(; router, port=8080)
start!(server)
```

## 📚 API Highlights

### Routing

```julia
router = Trie()

get!(router,     "/path", handler)
post!(router,    "/path", handler)
put!(router,     "/path", handler)
delete!(router,  "/path", handler)
patch!(router,   "/path", handler)
head!(router,    "/path", handler)
options!(router, "/path", handler)
```

### Typed Params and Wildcards

```julia
get!(router, "/models/:name", ctx -> text(param(ctx, :name)))
get!(router, "/models/:id::Int", ctx -> text("id=$(param(ctx, Int, :id))"))
get!(router, "/scores/:n::Float64", ctx -> text("n=$(param(ctx, Float64, :n))"))
get!(router, "/files/*", ctx -> text("serving: $(path(ctx))"))
```

### Route Groups

```julia
group!(router, "/api/v1") do g
    get!(g,  "/models", list_models)
    post!(g, "/predict/:id", run_prediction)
end
```

### Request and Response Helpers

```julia
# Request
path(ctx)
query(ctx)
queryparams(ctx)
header(ctx, "Content-Type")
body(ctx)
rawbody(ctx)

# Response
text("Hello")
html("<h1>Hi</h1>")
json("""{"ok":true}""")
redirect("/login")
fail(404, "Not Found")
```

### Middleware Pattern (Callable Struct)

```julia
struct WithAuth{H}
    handler::H
    token::String
end

function (m::WithAuth)(ctx::Context)::Response
    header(ctx, "Authorization") == "Bearer $(m.token)" || return fail(401)
    return m.handler(ctx)
end

get!(router, "/admin", WithAuth(admin_handler, ENV["SECRET"]))
```

## 🏗️ Architecture Snapshot

```text
Server
  -> Router (Trie)
  -> Core (HTTP parsing + serialization + worker flow)
  -> Backend (io_uring in lib/ciro.c)
  -> Interface (types/contracts)
```

## 🧪 Testing

```bash
cd lib && make
julia --project=. -e 'using Pkg; Pkg.test()'
```

## 📈 Benchmarks

```bash
cd benchmarks/khttp && cargo build --release
./benchmarks/khttp/target/release/server &
julia --project=. benchmarks/ciro_bench.jl &
./benchmarks/run_bench.sh
```

Requires oha:

```bash
cargo install oha
```

## 🔌 Extensibility

| Module | Role | Extension Direction |
|---|---|---|
| Backend | io_uring async I/O | Add alternative backend implementation |
| Interface | Shared types and contracts | Add custom logger/catcher abstractions |
| Router | Trie dispatch | Implement another router strategy |
| Core | Server runtime | Customize startup/worker orchestration |

## 📄 License

MIT
