# 3. SQLite is the truth; the ANN index is disposable

**Status:** accepted · 2026-08-31

## Context

Millions of moments need approximate nearest-neighbour search. The industry
answer is a vector database — Qdrant, pgvector, Weaviate. For a single Mac that
means running a server for a personal search tool.

Two lighter options exist. `sqlite-vec` is a dependency-free C extension, but it
is still pre-1.0 (0.1.10-alpha as of mid-2026) and warns about breaking changes.
USearch is an HNSW implementation with Swift bindings, `f16`/`i8` quantization,
and — critically — the ability to memory-map an index from disk instead of
loading it into RAM.

## Decision

**SQLite (via GRDB) is the single source of truth.** Assets, locations, moments,
transcripts, OCR, previews, jobs — and the embedding vectors themselves, stored
as int8 with a scale factor.

**USearch holds a derived HNSW graph**, memory-mapped for search. It can be
deleted at any moment and rebuilt from SQLite.

Full-text search is FTS5 with `unicode61 remove_diacritics 2`, which is what
makes *presupuesto* find *Presupuestó*.

Verified on this hardware: SQLite 3.51.0 with FTS5 available, USearch 2.26.2 with
`neon, neonhalf, neonsdot, neonfhm` acceleration.

## Consequences

**Good.** Two files are the entire storage story: `index.sqlite` and
`<model>.usearch`. No server, no ports, no daemon. A corrupted ANN index costs a
rebuild, not a library. Changing the visual model is a background reindex into a
parallel index, then a swap. Memory-mapping means millions of moments are ready
to search while the app holds tens of megabytes.

**Bad.** USearch's Swift wrapper keeps `length`/`capacity` internal, so the actor
tracks its own count in a sidecar file. No distributed or multi-machine search.
int8 quantization is lossy — measured cosine fidelity above 0.999, which is far
below the noise floor of the embedding itself.

## The arithmetic that settled it

27,000 videos × 30 GB ≈ **810 TB** of originals. One representation every 10 s at
512 dimensions ≈ 4.86 M vectors ≈ **2.5 GB in int8**. The index is five orders of
magnitude smaller than the footage. The real storage risk is thumbnails — one per
moment would be ~97 GB — which is why previews are a budgeted, evictable cache.
