# Ciro.jl

High-performance HTTP framework for Julia, built on Linux `io_uring` with a
portable sockets fallback, zero-copy request views, and type-stable routing.

## Overview

Ciro.jl is designed for serving machine learning models with maximum throughput
and minimum latency. It provides:

- **io_uring backend** for kernel-level async I/O, plus a portable `Sockets` backend
- **Thread-per-core architecture** with `SO_REUSEPORT`
- **Async executor** so slow handlers (model inference) never block the event loop
- **Streaming and SSE** with chunked framing and backpressure
- **Type-stable trie router** with typed parameters, groups, and wildcards
- **Zero-alloc steady state** via pool-based memory management
- **Minimal dependencies** — only `PicoHTTPParser`

## Module Structure

```
Ciro.jl
├── Interface   → Context, Request/Response, Stream, telemetry, abstract traits
├── Router      → trie routing with typed parameters
├── Runtime     → single dispatch pipeline + AsyncExecutor
├── HTTP        → connection state machine, serialization, AbstractIO seam
├── Backend     → io_uring primitives (UringIO) + SocketsIO adapter
└── Core        → Server, worker/event loop, connection handling
```

## API

```@autodocs
Modules = [Ciro]
```
