# Ciro.jl Implementation Plan

## Goal

Ciro is a small, fast HTTP/1.1 server for Julia applications with a first-class
path for model serving. It is not intended to replace the complete feature set
of HTTP.jl.

The project prioritizes:

- Correct request/response behavior over micro-optimizations.
- A small public API and explicit extension contracts.
- Linux and `io_uring` as the initial production target.
- Efficient binary bodies and predictable resource limits.
- Extensive unit, integration, stress, fuzz and regression tests.
- Normal Julia compilation and precompilation; AOT is not a design constraint.

## Non-goals for the first stable core

- HTTP/2 and HTTP/3.
- WebSockets, SSE and chunked transfer encoding.
- Multipart support.
- A general-purpose plugin registry in the request hot path.
- Multiple packages before the interfaces have proven stable.
- Backward compatibility with the current pre-release API.

## Target Architecture

```text
Ciro
├── Base          Request, Response, Headers, Context, contracts
├── HTTP          Incremental HTTP/1.1 state machine and serialization
├── Router        AbstractRouter, TrieRouter, custom routers
├── Execution     AbstractExecutor, sync/thread/model executors
├── Transport     AbstractTransport, fake transport, lifecycle
├── Backend       io_uring implementation and C ABI
└── Observability logging, metrics and error handling
```

The initial implementation remains one Julia package. Components are modular
through multiple dispatch and concrete fields, not through runtime reflection.

## Extension Contracts

### Router

```julia
abstract type AbstractRouter end
route!(router, method, pattern, endpoint)
match_route(router, method, target)
freeze!(router)
```

The result distinguishes `Matched`, `NotFound` and `MethodNotAllowed`. A custom
router may implement a specialized `dispatch(router, request, server)` path to
avoid generic route result allocations.

### Executor

```julia
abstract type AbstractExecutor end
execute!(executor, endpoint, context)
```

Initial implementations are `SyncExecutor` and a bounded executor suitable for
long-running model inference. Queue limits, overload responses and shutdown
behavior are part of the contract.

### Transport

```julia
abstract type AbstractTransport end
start!(transport, application)
stop!(transport)
send_response!(transport, token, response)
close!(transport, token)
```

`FakeTransport` is used for runtime contract tests; `CiroTransport` uses
`io_uring`.

### Plugins

Plugins are lifecycle extensions only: configuration, startup and shutdown.
They must not require a dynamic lookup for every request.

## Phases

### Phase 0: Foundation and API reset

- Replace the AOT-first design documentation.
- Define own `Request`, `Response`, `Headers` and `RequestContext` types.
- Stop exposing `PicoHTTPParser.Request` publicly.
- Define `Endpoint`, route result and transport contracts.
- Add lifecycle states and `freeze!` semantics.

**Gate:** contract and construction tests pass; no core public type depends on
the parser implementation.

### Phase 1: Request, response and context

- Implement byte-oriented request bodies.
- Implement case-insensitive request/response header access.
- Validate header names and values.
- Correct `HEAD`, `204` and `304` semantics.
- Use `NoParams` for routes without parameters.
- Keep context small and avoid per-request `Dict{Symbol,Any}`.

**Tests:** malformed headers, binary bodies, large bodies, status semantics,
CRLF rejection, allocation and inference checks where meaningful.

### Phase 2: Router and endpoints

- Rebuild the default trie router.
- Fix wildcard method handling.
- Add static routes, parameters, groups and `404`/`405` behavior.
- Add endpoint metadata without dynamic hot-path lookups.
- Add custom-router contract tests.
- Freeze routing configuration before serving.

**Gate:** default and custom routers pass the same contract suite.

### Phase 3: Reliable `io_uring` transport

- Replace the C ABI with opaque engine/connection/completion types.
- Return errors from every queue and submit operation.
- Track connection generation independently from file descriptors.
- Handle partial reads/writes and accept multishot termination.
- Add timeout, cancellation, cleanup and backpressure primitives.
- Honor host, port, backlog and connection limits.

**Tests:** native lifecycle, errors, FD reuse, partial I/O, cancellation,
timeouts, sanitizer builds and long-running stress tests.

### Phase 4: Incremental HTTP/1.1

- Add per-connection read state.
- Accumulate fragmented headers and bodies.
- Require and validate `Content-Length` for request bodies.
- Initially reject chunked, upgrade and `100-continue` explicitly.
- Preserve keep-alive behavior and define pipelining policy.

**Tests:** real sockets with fragmented input, multiple requests, malformed
lengths, timeouts, disconnects, slow clients and oversized input.

### Phase 5: Runtime and execution policies

- Compose router, endpoint, executor and transport in `Application`.
- Add synchronous execution for simple handlers.
- Add bounded worker execution for model inference.
- Define overload, timeout, cancellation and shutdown behavior.
- Add model-serving helpers outside the HTTP core.

**Tests:** slow handlers, full queues, failures, concurrent requests, model
limits, graceful shutdown and response ownership.

### Phase 6: Fake transport and contract testing

- Build a deterministic in-memory transport.
- Run common router/runtime tests against fake and native transports.
- Test token ownership, duplicate responses and closed connections.

**Gate:** application tests do not need native libraries unless testing the
native transport itself.

### Phase 7: Measured optimization

- Benchmark parsing, routing, context creation, execution, serialization and
  end-to-end latency independently.
- Remove avoidable copies and allocations based on measurements.
- Optimize binary body paths and response serialization.
- Add regression thresholds for latency, throughput and allocations.

No optimization is accepted solely because it looks type-stable or AOT-friendly.

### Phase 8: Optional capabilities

Only after the core is stable, evaluate separate modules for:

- TLS.
- Static files and `sendfile`.
- WebSockets or SSE.
- Streaming.

Each capability requires its own lifecycle, resource, security and integration
tests. HTTP/2 is explicitly outside the initial project scope.

### Phase 9: Distribution and release

- Add reproducible native builds and JLL artifacts.
- Separate portable Julia tests from Linux-native backend tests.
- Remove `-march=native` from release builds.
- Document supported Linux/kernel/liburing versions.
- Publish custom router and executor guides.
- Release only after stress, fuzz and benchmark gates pass.

## Test Strategy

Every phase follows:

1. Write contract tests first.
2. Implement the smallest behavior satisfying them.
3. Run unit tests and quality checks.
4. Run integration tests with real sockets when applicable.
5. Run sanitizers for C changes.
6. Run allocation/type inference checks only on measured hot paths.
7. Update documentation and benchmarks.

Required final coverage includes fragmentation, keep-alive, body limits,
timeouts, partial writes, client disconnects, FD reuse, overload, shutdown,
wildcards, custom routers, custom executors, fuzzed HTTP input and concurrent
model requests.

## Immediate Iteration Order

1. Define own request/context/response contracts.
2. Update tests to the new contracts.
3. Rework router results, endpoints and freeze behavior.
4. Add fake transport and runtime contract tests.
5. Rewrite the native transport lifecycle.
6. Implement incremental HTTP/1.1.
7. Add bounded execution for model serving.
8. Measure and optimize.
