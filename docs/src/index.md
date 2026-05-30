# Ciro.jl

High-performance HTTP framework for Julia, built on Linux `io_uring` with zero-cost middleware composition and type-stable routing.

## Overview

Ciro.jl is designed for serving machine learning models with maximum throughput and minimum latency. It provides:

- **io_uring backend** for kernel-level async I/O (with `AbstractBackend` trait for future cross-platform support)
- **Thread-per-core architecture** with SO_REUSEPORT
- **Zero-cost middleware** via functor composition (fully monomorphized) — lives in `ext/CiroMiddleware/`, opt-in with `using Ciro.Middleware`
- **Type-stable trie router** with typed parameters
- **Pool-based memory management** for zero-alloc steady state
- **Minimal dependencies** — only `PicoHTTPParser` v0.2

## Module Structure

```
Ciro.jl
├── Interface   → Types, Context, Response, abstract traits (AbstractBackend, AbstractRouter, AbstractLogger, AbstractCatcher)
├── Backend     → io_uring primitives, IOUringBackend <: AbstractBackend
├── Core        → Server, serialization, worker dispatch
├── Router      → Trie-based routing with typed parameters
└── ext/CiroMiddleware → Optional middleware (WithCORS, WithRateLimit, etc.)
```

## API

```@autodocs
Modules = [Ciro]
```
