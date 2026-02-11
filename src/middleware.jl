module Middlewares

using Dates
using ..Types

export Logger

"""
    Logger(req::Request, next::Function) -> Response

Logging middleware. Logs method, path, status, and duration.

Usage in `@routes`:
```julia
@routes MyApp begin
    middleware(Logger)
    ("GET", "/") => index_handler
end
```
"""
function Logger(req::Request, next)
    start_time = time_ns()

    response = next(req)

    elapsed_ms = (time_ns() - start_time) / 1_000_000

    # Use print with multiple args instead of string interpolation for trim-safety
    print("[")
    print(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
    print("] ")
    print(req.method)
    print(" ")
    print(req.path)
    print(" -> ")
    print(response.status)
    print(" (")
    print(round(elapsed_ms, digits=2))
    println("ms)")

    return response
end

end
