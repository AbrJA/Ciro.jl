# Problemas pendientes de Ciro

Este documento reúne los problemas identificados durante la revisión de la implementación. Está pensado como una lista de trabajo para llevar Ciro desde un prototipo funcional hacia un servidor HTTP apto para producción.

Los tests unitarios actuales pasan (`511/511`), pero todavía no cubren suficientemente el comportamiento sobre sockets reales, fragmentación TCP, concurrencia, backpressure, timeouts ni shutdown con conexiones activas.

## Prioridad crítica

### 1. Implementar parsing HTTP incremental

**Referencias:** `src/Core/worker.jl:62-110`

El handler realiza una sola lectura y asume que contiene el request completo. TCP no conserva los límites de los requests, por lo que un request puede llegar fragmentado o varios requests pueden llegar en una sola lectura.

Casos afectados:

- headers fragmentados entre varias lecturas;
- body fragmentado;
- múltiples requests en una misma lectura;
- keep-alive;
- pipelining;
- `Expect: 100-continue`.

**Trabajo requerido:** crear un estado por conexión que acumule bytes, detecte el final de headers, determine `Content-Length` o transferencia chunked, procese requests completos y conserve bytes sobrantes para el siguiente request.

### 2. Añadir timeouts y protección contra slowloris

**Referencias:** `docs/INFRA_BLOCKED_FEATURES.md:31-51`

Las conexiones pueden permanecer indefinidamente esperando datos durante el request o después de una respuesta keep-alive.

**Riesgos:** agotamiento de file descriptors, conexiones ocupadas indefinidamente y denegación de servicio por clientes lentos.

**Trabajo requerido:** añadir timeout de lectura, timeout de headers, timeout de body y timeout de keep-alive. Puede implementarse inicialmente con `IORING_OP_TIMEOUT` o una estructura de timers/reaper.

### 3. Corregir el límite de tamaño del body

**Referencias:** `src/Core/worker.jl:84-89`

Actualmente `max_body_size` compara el total de bytes leídos, incluyendo headers, y solo considera una lectura. No representa el tamaño real del body.

**Riesgos:** requests válidos rechazados por headers grandes y bodies grandes aceptados cuando llegan fragmentados.

**Trabajo requerido:** limitar por separado el tamaño máximo de headers y body, validar `Content-Length`, controlar acumulación incremental y rechazar transferencias que excedan el límite.

### 4. Corregir lifecycle de buffers y errores de escritura

**Referencias:** `src/Core/worker.jl:43-47`, `src/Backend/pool.jl:80-165`

Cuando una operación de I/O falla, el código libera la conexión, pero puede dejar buffers y flags pendientes en `PendingWrites`.

**Riesgos:** fugas de memoria, estado stale asociado a un file descriptor y cierre incorrecto cuando el FD se reutiliza.

**Trabajo requerido:** centralizar la ruta de cleanup para toda conexión, eliminar siempre el pending write, limpiar `close_after`, cerrar el FD exactamente una vez y liberar la conexión solo cuando no tenga operaciones en vuelo.

### 5. Manejar correctamente el fin de un accept multishot

**Referencias:** `lib/ciro.c:256-266`

El backend no expone las flags del CQE, incluyendo `IORING_CQE_F_MORE`. Si el accept multishot deja de estar activo, Julia no sabe que debe reprogramarlo.

**Riesgo:** el servidor puede dejar de aceptar nuevas conexiones sin detenerse explícitamente.

**Trabajo requerido:** exponer flags del CQE, detectar la pérdida de `IORING_CQE_F_MORE`, reencolar el accept y manejar errores transitorios y permanentes.

### 6. No ocultar errores de reserva y submission de SQEs

**Referencias:** `lib/ciro.c:30-35`, `lib/ciro.c:144-179`, `lib/ciro.c:226-236`

Las funciones de queue retornan `void` y descartan errores cuando no hay SQE disponible o falla una submission.

**Riesgo:** una conexión puede quedar bloqueada sin que Julia pueda detectarlo ni limpiarla.

**Trabajo requerido:** devolver códigos de error, distinguir errores recuperables de fatales, aplicar backpressure y añadir una ruta de cleanup cuando una operación no pueda ser encolada.

## Prioridad alta

### 7. Corregir wildcards para respetar el método HTTP

**Referencias:** `src/Router/Router.jl:101-104`, `src/Router/Router.jl:246-248`

El nodo wildcard almacena un único handler sin asociarlo al método. Una ruta registrada como `GET /files/*` puede terminar respondiendo a otros métodos.

**Trabajo requerido:** almacenar handlers wildcard por método, aplicar la misma lógica de `404` y `405` que para rutas estáticas y generar correctamente el header `Allow`.

### 8. Hacer efectivos `host` y `backlog`

**Referencias:** `src/Core/server.jl:22-34`, `lib/ciro.c:61-95`

Los valores configurados en `Server` no se transmiten al backend. El socket C siempre usa `INADDR_ANY` y backlog `8192`.

**Trabajo requerido:** pasar host y backlog a `init_engine`, resolver bindings IPv4/IPv6 y validar errores de resolución y bind.

### 9. Corregir el shutdown y el drenaje de operaciones en vuelo

**Referencias:** `src/Core/server.jl:36-73`, `src/Core/worker.jl:72-110`

`_in_flight` solo cubre la ejecución del handler y se decrementa antes de que termine la escritura del response. El shutdown puede considerar terminado un request mientras todavía hay I/O pendiente.

**Trabajo requerido:** distinguir requests en ejecución de operaciones de escritura pendientes, dejar de aceptar conexiones nuevas, decidir cómo cerrar keep-alive y esperar correctamente hasta el timeout configurado.

### 10. Corregir la semántica HTTP de HEAD, 204 y 304

**Referencias:** `src/Core/serialize.jl:44-60`, `src/Router/Router.jl:115-120`

El serializador agrega `Content-Length` genéricamente. HTTP tiene reglas especiales para respuestas `HEAD`, `204` y `304`.

**Trabajo requerido:**

- para `HEAD`, enviar los headers correspondientes al GET sin body;
- no enviar body en `1xx`, `204` y `304`;
- no generar `Content-Length` inválido para `204`;
- añadir tests de conformidad.

### 11. Añadir validación y límites de headers

**Referencias:** `src/Interface/response.jl`, `src/Core/serialize.jl`

Los headers de respuesta se aceptan sin validar nombres ni valores.

**Riesgos:** respuestas inválidas, inyección CRLF si se usan valores controlados por usuarios y consumo excesivo de memoria.

**Trabajo requerido:** validar nombres y valores de headers, rechazar `CR`/`LF`, imponer límites de cantidad y tamaño, y decidir el comportamiento ante headers duplicados.

### 12. Añadir backpressure y límites de conexiones

**Referencias:** `src/Backend/pool.jl`, `lib/ciro.c`

El pool de conexiones crece bajo demanda y no existe un límite global claro de conexiones activas, writes pendientes o memoria usada por cliente.

**Trabajo requerido:** configurar máximo de conexiones, máximo de requests por conexión, máximo de writes pendientes y política explícita cuando se agotan recursos.

## Prioridad media

### 13. Reducir type instability y allocations del router

**Referencias:** `src/Interface/types.jl:85-94`, `src/Router/Router.jl:68-73`, `src/Router/Router.jl:183-201`

`RouteResult.handler` y los handlers del trie usan `Any`. Además, el routing crea un vector de parámetros por request y realiza conversiones/copia de strings.

**Trabajo requerido:** medir primero con `@code_warntype`, `BenchmarkTools` y `Profile`; después evaluar representación de handlers, parámetros y vistas de strings sin sacrificar compilación ni mantenibilidad.

### 14. Corregir y ampliar los benchmarks

**Referencias:** `benchmarks/ciro_bench.jl:8`, `README.md:171-184`

El benchmark usa `param(:id)`, aunque la API requiere `param(ctx, :id)`. Además, no existe comparación reproducible contra facil.io.

**Trabajo requerido:** corregir el benchmark, fijar payloads y configuración, medir latencia p50/p95/p99, throughput, conexiones keep-alive, errores y consumo de memoria. Comparar al menos:

- handler estático en C;
- handler Julia con facil.io;
- handler Julia con Ciro;
- payloads pequeños y grandes;
- una y varias threads.

### 15. Implementar streaming, chunked, SSE y WebSockets

**Referencias:** `docs/INFRA_BLOCKED_FEATURES.md:7-29`, `docs/INFRA_BLOCKED_FEATURES.md:55-63`

El backend actual está diseñado para un response completo por request. No soporta correctamente respuestas incrementales ni conexiones de larga duración.

**Trabajo requerido:** diseñar una abstracción de conexión persistente, writes múltiples, writev/scatter-gather, control de backpressure y lifecycle explícito para conexiones streaming.

### 16. Añadir TLS y evaluar HTTP/2

Actualmente el servidor no ofrece una ruta integrada para TLS ni HTTP/2.

**Trabajo requerido:** decidir si estas capacidades pertenecen al core, a paquetes separados o a un reverse proxy recomendado. Documentar claramente las capacidades soportadas.

## Portabilidad y distribución

### 17. Formalizar la distribución del backend nativo

**Referencias:** `src/Backend/Backend.jl:18-28`, `README.md:31-42`

La instalación requiere compilar manualmente `lib/ciro.so`. No existe todavía una distribución robusta mediante artefactos binarios.

**Trabajo requerido:** crear un paquete JLL con BinaryBuilder, seleccionar la biblioteca mediante `Libdl`, validar versiones de ABI y eliminar la dependencia de una ruta fija dentro del repositorio.

### 18. Evitar `-march=native` en binarios distribuidos

**Referencias:** `lib/Makefile:21-24`

`-march=native` genera código específico para la máquina de compilación.

**Riesgo:** el binario puede fallar o perder compatibilidad en otro servidor.

**Trabajo requerido:** usar flags portables en releases y reservar `-march=native` para builds locales explícitamente optimizados.

### 19. Separar la CI portable de la CI del backend

**Referencias:** `.github/workflows/CI.yml:14-35`, `test/backend_test.jl:5-7`

La CI prueba Windows y macOS aunque el backend requiere Linux. Los tests nativos se omiten cuando `ciro.so` no está disponible.

**Trabajo requerido:**

- mantener tests portables para router, interfaces y serialización;
- añadir un job Linux que compile y pruebe el backend real;
- no considerar la CI verde como validación del servidor nativo cuando el backend fue omitido;
- añadir sanitizers, tests de stress y tests de integración.

### 20. Revisar el modelo de threads de Julia

**Referencias:** `src/Backend/eventloop.jl:97-122`

`Threads.@spawn` no garantiza por sí mismo una correspondencia estable entre task y thread. El diseño documenta “un ring por thread”, pero esa propiedad debe comprobarse y hacerse explícita.

**Trabajo requerido:** validar migración de tasks, comportamiento de `ccall` bloqueantes, afinidad, número de workers y acceso a estado thread-local. Documentar restricciones de uso de handlers.

## Cobertura de pruebas requerida

Antes de considerar resueltos los problemas principales, añadir tests de integración que cubran:

- headers y requests fragmentados;
- body fragmentado y `Content-Length` incorrecto;
- múltiples requests por conexión;
- keep-alive y cierre por timeout;
- `Expect: 100-continue`;
- chunked request/response si se soporta;
- respuestas parciales y errores de write;
- cierre abrupto del cliente;
- accept multishot agotado;
- límite de conexiones y memoria;
- wildcard con cada método HTTP;
- `HEAD`, `204` y `304`;
- shutdown con handlers lentos y writes pendientes;
- pruebas concurrentes con varias threads;
- fuzzing del parser y headers.

## Orden recomendado de resolución

1. Parsing incremental y estado por conexión.
2. Límites de headers/body y timeouts.
3. Cleanup correcto de conexiones, buffers y SQEs.
4. Accept multishot y shutdown confiable.
5. Correcciones HTTP y routing wildcard.
6. Tests de integración, stress y fuzzing.
7. Distribución binaria y CI nativa.
8. Optimización de allocations y type stability.
9. Streaming, SSE, WebSockets, TLS y HTTP/2.
10. Benchmarks comparativos reproducibles.
