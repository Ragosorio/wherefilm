# WhereFilm scale pass — 2026-09-02

Second optimization pass, run immediately after `PERFORMANCE-PASS-2026-09-02.md`.

## Why there was anything left to find

The previous pass measured a fixture of **9 vectors and 1 transcript chunk** and
reported a warm visual search of 1.78 ms. Its own closing section named the
problem: *"Build a medium fixture with at least thousands of vectors… The current
nine-vector fixture cannot locate the recall/latency knee."*

That was the right instinct, and understated. On a library the size the product
is actually for, the same code path measured **1,472 ms** — roughly 800× the
published number. Nothing had regressed. The fixture was simply too small for any
of the costs that matter to exist yet.

So the first work of this pass was building a library big enough to have an
opinion, and everything below is measured on it.

## The measurement fixture

`wherefilm bench-fixture` (hidden subcommand, `Sources/WhereFilmCLI/BenchmarkFixture.swift`)
synthesizes a catalog without decoding a frame:

| | |
|---|---:|
| assets | 40,000 |
| moments / embeddings | 208,801 |
| transcript chunks | 1,442,882 |
| FTS5 rows | 1,548,052 |
| OCR rows | 25,170 |
| database | 652 MB |
| HNSW graph | 233 MB |

**What is real and what is not.** The schema, the FTS5 index, the int8 vector
codec, the HNSW graph and every query path under measurement are the product's
own. The pixels are not. Embeddings are constructed to sit at a chosen cosine
similarity from a *real* MobileCLIP text vector — exactly, by projecting a random
direction off the centroid and recombining with weights `t` and `√(1-t²)` — so
scores against a real query land in MobileCLIP's true 0.14–0.30 band instead of
wherever random noise happens to fall.

Consequence, honoured throughout: **this fixture measures latency, memory and
scaling. It cannot measure recall or ranking quality.** Every quality number in
this document comes from the seven-file real-media fixture instead.

Reproduce:

```bash
wherefilm bench-fixture --database <db> --assets 40000 && wherefilm rebuild-index --database <db>
```

## 1. Two defects that were not performance defects

Both were found while benchmarking, and both matter more than any timing below.

### The app could not open its own database

The real index on this Mac — 151 assets — **failed to open entirely**, on the
current build and on the previous release alike:

```
SQLite error 19: FOREIGN KEY constraint violation - from previews(momentID) to moments(momentID)
```

It held 262 preview rows and 119 OCR rows pointing at moments that no longer
existed. SQLite verifies deferred foreign keys when a migration commits, so every
migration after `v1` failed on that pre-existing damage. `grdb_migrations`
confirmed it: `v1` applied, `v2-analysis-state` and `v3-coverage-stats` never.
The database had been unopenable since `v2` shipped, and the failure had nothing
to do with the migration being applied.

`IndexStore.repairOrphanedDerivedRows` now drops derived rows whose parent is
gone, before migrating. Only previews, OCR, embeddings and orphaned child rows
are touched — all explicitly regenerable state that the pipeline knows how to
rebuild. No original, transcript or asset identity is affected. The alternative,
a database nobody can open, protects nothing.

It runs only when a migration is pending, because that is the only moment SQLite
checks: 260 ms on a 1.4 M-row library versus 20 ms to open a healthy one. Once
per app upgrade is right; every launch is not.

Verified on a copy of the real damaged index: it now opens, all four migrations
apply, `PRAGMA foreign_key_check` is clean, and all 151 assets survive.

### A missing 6-byte file silently made search 160× slower

`VectorIndex` cached its vector count in a `.usearch.meta` sidecar written with
`try?`. When this Mac's disk filled during a rebuild, the sidecar was lost beside
a graph that was otherwise fine. The count read back as zero, the ANN index was
treated as empty, and every search fell through to an exhaustive scan of 208,801
vectors — **9.1 s instead of milliseconds**, with nothing anywhere saying why.

The pinned USearch wrapper exposes the real graph length. The count now comes
from the graph, and the sidecar is deleted rather than written. `wherefilm doctor`
also reports the live vector count and warns when a graph is present but reports
none.

## 2. What the time was actually going on

Stage timings did not exist before this pass; `SearchTimings` adds them, and they
are printed by `--benchmark-runs`. They immediately paid for themselves — the
first attempt at the prefix guard below made two of three queries *slower*, and
the breakdown showed why in one line instead of an afternoon.

For `atardecer frente al mar`, after all changes:

```
text 175.04 ms · fuse 0.20 ms · hydrate 4.32 ms · encode 0.01 ms
ann 1.65 ms · moments 0.66 ms · fuse2 0.27 ms · hydrate2 3.89 ms
```

HNSW was never the problem. It answers in **1.6–1.8 ms** over 208,801 vectors,
flat from depth 10 to depth 600 — so the `efSearch` sweep the research brief asked
for has nothing to find here, and the pinned wrapper still exposes no setter for
it. The cost was, and remains, FTS5.

## 3. Changes

### One FTS scan instead of three

`SearchEngine` ran the same MATCH three times — transcript kinds, OCR kinds,
metadata kinds — scoring and sorting the same matched rows each time:
1.11 s + 0.72 s + 0.74 s on this index.

Merging them has a catch worth recording. FTS5 has a fast path for exactly
`ORDER BY rank LIMIT n`, keeping a bounded heap instead of materialising every
match; adding `AND kind IN (…)` defeats it, because the filter must read each
matched row's content to learn its kind. Measured on one query: **0.07 s bounded
and unfiltered versus 0.20 s filtered.**

So the fast path is taken as written, over-fetching enough rows to fill every
group, and the split happens in Swift. **This is exact, not approximate:**
filtering a globally rank-ordered list by kind preserves each kind's own order,
and a group can only come up short if the scan was truncated — in which case that
group alone gets a targeted top-up query.

### A prefix wildcard that asks the index what it costs

Every single-word term got a `*` suffix, so `"presupuest"` finds `"presupuesto"`.
On a real corpus that is not uniformly cheap: `"camis"*` reaches 62 K rows and
ranks in 50 ms, while `"man"*` reaches **516,849 rows — a third of the whole
index**, because Spanish is full of words like *manera* — and ranks in 490 ms,
three times over.

Word length does not predict this; only the vocabulary does. FTS5's own term
dictionary, exposed through a new `fts5vocab` table that stores nothing, answers
the question directly with a range scan over the term index. The wildcard is kept
where it is cheap and dropped where it is not, against a budget derived from
measurement (~1 µs per matched row, so 50,000 documents ≈ 50 ms).

The first version of this guard judged breadth as a *share* of the index, which
required `SELECT count(*) FROM search_index` — itself a full scan, ~150 ms per
search. It made the filename query 3× slower. The stage timings caught it; the
budget is now absolute and the lookup is free.

### Batched result hydration

`build()` issued up to three preview queries per result card plus one volume
lookup per location — up to a hundred round trips for thirty results, before
anything reached the screen. Now three queries total: exact previews by moment,
nearest-frame fallback for the cards that need one, and volumes in bulk.
Hydration is **4 ms for 30 results**.

(The nearest-frame query wanted a correlated `LIMIT 1`, but SQLite cannot see an
outer CTE column from inside a joined subquery. A window function gives the same
answer and still uses the `(assetID, startSeconds)` index. The existing
"a dialogue hit still shows a picture" test caught the first attempt.)

### Exhaustive fallback stops re-sorting

`LinearVectorSearch` called `sort` on the entire top-K every time a candidate beat
the worst survivor — ~2,500 comparisons to move one element, repeated across every
vector in the library. Now a binary insertion, with most candidates rejected on
the first comparison. This is the path any library takes before its graph is
built. Warm, over 208,801 vectors: **445 ms → 373 ms.**

## 4. Benchmarks

40,000 assets · 208,801 moments · 1,548,052 FTS rows. Release build, 1 cold +
19 warm in-process runs, p50.

| Query | First useful (before → after) | Stable (before → after) |
|---|---|---|
| `a man wearing a blue shirt in an interview` | 1464.06 → **51.62 ms** (−96.5%) | 1472.55 → **57.70 ms** (−96.1%) |
| `atardecer frente al mar` | 247.94 → **177.66 ms** (−28.3%) | 256.05 → **184.22 ms** (−28.1%) |
| `camisa azul presupuesto entrevista` | 257.04 → **191.56 ms** (−25.5%) | 265.26 → **198.04 ms** (−25.3%) |
| `INTERVIEW_00197` | 50.92 → **39.57 ms** (−22.3%) | 50.92 → **39.57 ms** (−22.3%) |
| `carro rojo en la calle` | 229.23 → **164.79 ms** (−28.1%) | 237.47 → **171.30 ms** (−27.9%) |
| `reunion pizarra diagrama` | 253.88 → **184.89 ms** (−27.2%) | 262.06 → **191.51 ms** (−26.9%) |

Thirty-query burst, one process:

| | Before | After | Delta |
|---|---:|---:|---:|
| Wall | 8.23 s | 6.49 s | −21.1% |
| CPU (user+sys) | 8.12 s | 6.28 s | −22.7% |
| Max RSS | 210.5 MB | 208.4 MB | −1.0% |

Against the brief's aspirational budgets, on this library: first useful result
under 50 ms is met only by the English visual query; the Spanish queries sit at
~180 ms. Stable ranking is under the 250 ms budget for every query measured.

## 5. Quality impact

Measured on the seven-file **real-media** fixture — genuine photographs and real
Spanish speech — because the synthetic fixture cannot speak to this.

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Top-1 consistency | 9/12 (75.0%) | 9/12 (75.0%) | 0 |
| Recall@5 | 12/12 (100%) | 12/12 (100%) | 0 |
| Recall@10 | 12/12 (100%) | 12/12 (100%) | 0 |
| MRR | 0.836 | 0.836 | 0 |
| Top-5 overlap in query clusters | 83.9% | 83.9% | 0 |

Every individual case returned the identical rank. No case changed in either
direction.

On the large fixture, ranked output was compared directly against the baseline
binary. The top 6 of the visual query are identical and in the same order; the
top 1 of the filename query is identical. Differences appear only among results
carrying the *same displayed score* — ties whose order was always arbitrary.

## 6. Accepted trade-offs

- A prefix wildcard is dropped for any term reaching more than 50,000 documents.
  On this corpus that affects `man*`, which was matching a third of the library
  through *manera* — noise, not spelling tolerance. It is a real behaviour change
  and could in principle drop a legitimate morphological match on a term that
  happens to be very common; the term is still searched exactly.
- The grouped FTS scan issues one extra targeted query per starved channel when
  the wide scan is truncated. For a query where a channel has no matches at all,
  that top-up always fires and finds nothing. Measured net effect is still
  positive on every query tested.
- The orphan repair deletes derived rows rather than refusing to open. Previews
  and OCR are regenerable; the enrichment jobs re-run.

## 7. Rejected or not attempted

- **`efSearch` sweep.** Measured as pointless *here* rather than declined: ANN
  latency is 1.6–1.8 ms and flat from depth 10 to 600, so the knee the brief
  asks about is not in the retrieval stage on this data. The pinned USearch
  wrapper still exposes no setter.
- **Two-stage ANN with exact reranking.** No case for it while ANN costs 1.6 ms
  out of a 184 ms query.
- **Changing the vector store, quantization, or model.** Nothing measured points
  at any of them.
- **Claiming an indexing speedup.** No indexing hot path was changed. The one
  figure recorded is a full HNSW rebuild of 208,801 vectors in 219 s.

## 8. Next opportunities, with evidence

1. **FTS is now the entire remaining cost** — 175 ms of a 184 ms Spanish query.
   The terms genuinely match ~130 K rows. Worth investigating: a smaller
   per-channel `channelDepth` (currently 300, and fusion discards most of it),
   or splitting transcripts into their own FTS table so a dialogue query never
   scans filename rows.
2. **`IndexStore.markMissing`** loads every location on a volume into memory and
   updates row by row (`Sources/WhereFilmCore/Database/IndexStore.swift`). On a
   500 K-file drive that is 500 K objects and 500 K UPDATEs. One SQL statement
   against a temporary table of seen paths would replace it.
3. **`LibraryScanner.ingest`** opens a read transaction and a write transaction
   per file even when nothing changed. A rescan of an unchanged 100 K-file
   library is 200 K transactions; the unchanged path only refreshes `lastSeenAt`
   and could be batched.
4. **Self-healing ANN.** The product now *detects* a graph that reports zero
   vectors while embeddings exist, but only in `doctor`. The zero-maintenance
   goal argues for enqueueing a rebuild automatically.
5. **Cold start** remains unmeasured and unimproved, as in the previous pass.

## Validation

- `swift test`: **72/72 passed** in 15 suites (3 new: orphan repair, grouped FTS
  equivalence, prefix breadth).
- Quality on real media: unchanged on every metric and every individual case.
- Damaged real database: opens, migrates fully, `foreign_key_check` clean.
- `git diff --check`: clean.
- Not performed, each a separate gate: commit, push, universal build,
  notarization, release.
