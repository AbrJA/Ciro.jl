# Reporte de Iteración — Fase Runtime Modular

> Fecha: 2026-08-24
> Estado: tests verdes (573/573 en `julia --project=. test/runtests.jl`,
> incluyendo la suite oficial `Pkg.test()`)

## 1. Revisión de los cambios anteriores

### Validación realizada

- La suite completa pasó antes de tocar el runtime (`539/539` con `Pkg.test()`).
- Revisé `Request`, `RequestContext`, `Endpoint`, `freeze!`, wildcards por
  método y `AbstractExecutor` contra el plan (`IMPLEMENTATION_PLAN_V2.md`).

### Problemas encontrados y corregidos

1. **El split de `target` usaba aritmética de índices byte-frágil.**
   `Request` separaba `path`/`query` con `findfirst(==(UInt8('?')), codeunits(...))`
   y slicing manual. Eso funciona para ASCII, pero es frágil con UTF-8 y
   duplicaba lógica. Se extrajo `_split_target` usando `findfirst`/`prevind`/
   `nextind`, que es correcto por índices de caracteres.

2. **Sin validación en el constructor público de `Request`.**
   Cualquier string era aceptado como method/target, permitiendo objetos
   inválidos desde código de usuario y tests. Ahora se exige método no vacío y
   target con `/` inicial (el constructor interno desde el parser no valida de
   nuevo: el parser ya validó).

3. **Test roto en `runtime_test` por expectativa incorrecta.**
   Escribí `@test_throws` para una operación válida (responder a un token
   pendiente del transporte correcto). Se corrigió el test y se añadió la
   detección de respuesta duplicada en `FakeTransport`, que es el invariante
   realmente valioso.

4. **Shadowing de nombres en tests globales.**
   Los tests originales reutilizan `req`, `ctx` y `raw` en scope global de
   `@testset`, lo que enmascaró un fallo durante la migración de `Context`.
   Los nuevos tests usan funciones locales (`request_contract_test.jl`) y
   bloques `let` para evitar esta clase de errores.

## 2. Lógica detrás de los cambios

### `Request` propio (desacoplamiento del parser)

La API pública ya no expone `PicoHTTPParser.Request`. Razones:

- Permite cambiar de parser o hacerlo incremental sin romper handlers.
- `path`/`query` se calculan una vez en el límite, no en cada acceso.
- Los tests de runtime ya no necesitan bytes HTTP válidos para probar la lógica.

Los adaptadores `header(::PicoHTTPParser.Request, ...)` se mantienen como puente
temporal para el backend actual; están marcados para eliminación cuando el
nuevo transporte `io_uring` emita directamente `Ciro.Request`.

### `Endpoint` con metadata

Las rutas guardan `Endpoint(handler; metadata)` en lugar de funciones crudas.
Esto habilita:

- `ModelEndpoint`-style metadata para executors (sin `Dict` por request).
- Routers generados que devuelven endpoints completamente tipados.
- HEAD automático conservando metadata.

### `freeze!`

Congelar antes de servir evita mutación concurrente del router y abre la puerta
a optimizaciones en el arranque (tablas inmutables, routers compilados).
`freeze!` es idempotente y forma parte del contrato `AbstractRouter`.

### `AbstractExecutor`

El dispatch ya no invoca al handler directamente: `execute!(executor, endpoint,
ctx)`. `SyncExecutor` es el default de overhead cero; la separación es la base
para `ThreadPoolExecutor`/`ModelExecutor`/`BatchExecutor` sin tocar el core.

## 3. Nuevo módulo Runtime (transport-independent)

Inspirado en Keel, pero adaptado a Ciro sin su sobrecoste:

| Concepto Keel | Versión Ciro | Diferencia clave |
|---|---|---|
| `Application` | `Application{R,E,L,C,T}` paramétrico | campos concretos, sin `Any` |
| `FakeTransport` | `FakeTransport` con tokens `owner+stream` | ownership estricto |
| `HandlerContext` | `RequestContext{R,P}` | sin `Dict{Symbol,Any}` por request |
| `Vector{AbstractMiddleware}` | omitido | fuera del hot path hasta diseñarlo |
| plugin registry dinámico | omitido | solo lifecycle si se reintroduce |

### Contrato de transporte

```julia
abstract type AbstractTransport end
start_transport!(transport, handler)
stop_transport!(transport)
send_response!(transport, token, response)
close!(transport, token)
```

`TransportToken{owner, stream}` previene mezclar tokens entre transports y
será la base para la generación por conexión en el backend nativo.

### `dispatch(app, request)`

Pipeline puro request→response: route lookup → 404/405 → `RequestContext` →
executor → normalización a `Response` → catcher. Ninguna operación de I/O.
Esto es exactamente lo que `FakeTransport` permite testear sin sockets.

### Cobertura nueva (13 testsets, ~90 assertions)

- dispatch, parámetros, 404/405, errores, retorno no-Response;
- executor personalizado en runtime;
- router personalizado mínimo (contrato `AbstractRouter` completo);
- freeze idempotente y rechazo de rutas tardías;
- FakeTransport: ownership, ciclo de vida, tokens cerrados, duplicados;
- `serve!` drena y detiene el transporte fake.

## 4. Decisión sobre estructura de paquetes

La estructura propuesta (`CiroBase`, `CiroRouter`, `CiroRuntime`,
`CiroExecution`, `CiroBackend`, `CiroObservability` como paquetes separados) es
correcta conceptualmente, pero **prematura**. Motivos:

1. Los contratos acaban de nacer; versionarlos entre paquetes costaría más que
   refactorizarlos dentro de un repo.
2. El sistema de módulos internos ya da la misma separación de
   responsabilidades sin overhead de releases múltiples.
3. Ningún consumidor externo de `CiroBase` existe todavía.

**Decisión:** mantener un solo paquete con módulos internos
(`Interface`, `Router`, `Core`, `Runtime`, `Backend`). Extraer a paquetes
cuando haya al menos una implementación externa real (p. ej. un router de
terceros). El plan V2 ya documenta esta decisión.

## 5. Estado actual y siguiente paso

Hecho:

- [x] Request/Response/Context desacoplados del parser
- [x] Endpoint + metadata
- [x] freeze! en router y aplicación
- [x] AbstractExecutor + SyncExecutor
- [x] Application + FakeTransport + contract tests

Siguiente fase (Backend io_uring):

1. Cleanup centralizado de conexiones/buffers en errores de I/O.
2. Estado por conexión (`READING_HEADERS` → `READING_BODY` → ...).
3. Errores explícitos en las operaciones de queue (no más `void` silencioso).
4. Parsing incremental con límites de headers/body.
5. `CiroTransport <: AbstractTransport` que emitirá `Ciro.Request` y consumirá
   `Response` vía `Application`, cerrando el ciclo transport-independent.
