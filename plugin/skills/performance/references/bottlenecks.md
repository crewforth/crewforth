# Common bottlenecks

| Area | Pattern | Fix |
|---|---|---|
| **DB** | N+1 query, missing index, `SELECT *`, table scan | eager/batch loading, index (db-migration), only needed columns |
| **Memory** | needless allocation, holding large objects, leak | pooling, streaming, releasing references |
| **Async** | wrong sync/async boundary, blocking I/O, serial await | parallel await, non-blocking I/O |
| **Network/payload** | oversized response, no compression, chatty API | pagination, field selection, gzip, batch (api-design) |
| **Cache** | repeated expensive computation, no/wrong cache | cache at the right layer + correct invalidation |
| **Frontend** | needless render, large bundle, blocking resource | memo, code-split, lazy, critical CSS |

## Caching — a wrong key is a data leak, not a slow page
A cache that serves one user's response to another is a security defect that looks like a speed-up. Before adding
or reviewing one:
- **The key holds everything the response depends on:** tenant, viewer (or role), locale, permissions, feature
  flags, and the query itself. A value that changes the response and is missing from the key is the leak.
- **Errors are not cached;** a cached "not found" lives shorter than a cached hit.
- **Stampede guard:** when a hot key expires, one request rebuilds it and the rest wait or get the stale value
  (request coalescing, a lock, or early refresh).
- **Measured:** hit rate and the latency it saves, read from the running system. A cache with no measured hit rate
  is a cost and a correctness risk with no shown benefit.
