# Ciro.jl

[![Build Status](https://github.com/AbrJA/Ciro.jl/workflows/CI/badge.svg)](https://github.com/AbrJA/Ciro.jl/actions?query=workflow%3ACI+branch%3Amain)

A high-performance REST API framework for Julia built on Linux's `io_uring` for asynchronous I/O.

## Features

- **High Performance**: Built on `liburing` for efficient async I/O with zero-copy operations
- **Multithreaded**: Automatic load balancing across threads using `SO_REUSEPORT`
- **Zero Allocations**: Optimized response generation with buffer pooling
- **Simple API**: Express-like routing with path parameters

## Requirements

- Linux kernel 5.19+ (for multishot accept)
- liburing development headers (`apt install liburing-dev`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/AbrJA/Ciro.jl")
```

Build the C library:
```bash
cd ~/.julia/packages/Ciro/xxx/lib
gcc -shared -fPIC -o ciro.so ciro.c -luring
```

## Quick Start

```julia
using Ciro

# Define routes
Ciro.get("/") do req, params
    Ciro.text("Hello, World!")
end

Ciro.get("/users/:id") do req, params
    Ciro.json(Dict("user_id" => params["id"]))
end

Ciro.post("/data") do req, params
    Ciro.text("Received: $(String(req.body))")
end

# Start server (uses all available threads)
Ciro.start_server(8080)
```

## API

### HTTP Methods

```julia
Ciro.get(handler, path)
Ciro.post(handler, path)
Ciro.put(handler, path)
Ciro.delete(handler, path)
Ciro.patch(handler, path)
Ciro.options(handler, path)
Ciro.head(handler, path)
```

### Response Helpers

```julia
Ciro.text(body; status=200)      # Plain text response
Ciro.json(data; status=200)      # JSON response
Response(status, body, headers)  # Custom response
```

### Middleware

```julia
Ciro.use(Ciro.Logger)  # Add logging middleware
```

## Performance Tips

1. **Start Julia with multiple threads**: `julia -t auto`
2. **Pre-compile before benchmarking**: Run a few requests first
3. **Use static strings** in responses when possible

## Benchmarking

```bash
# Simple benchmark
wrk -t4 -c1000 -d30s http://localhost:8080/

# High concurrency
wrk -t8 -c10000 -d30s http://localhost:8080/
```

## License

MIT License - see [LICENSE](LICENSE)
