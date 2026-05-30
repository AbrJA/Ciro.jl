# Ciro.jl

High-performance HTTP framework for Julia, built on Linux `io_uring` with zero-cost middleware composition and type-stable routing.

## Overview

Ciro.jl is designed for serving machine learning models with maximum throughput and minimum latency. It provides:

- **io_uring backend** for kernel-level async I/O
- **Thread-per-core architecture** with SO_REUSEPORT
- **Zero-cost middleware** via functor composition (fully monomorphized)
- **Type-stable trie router** with typed parameters
- **Pool-based memory management** for zero-alloc steady state

## API

```@autodocs
Modules = [Ciro]
```
