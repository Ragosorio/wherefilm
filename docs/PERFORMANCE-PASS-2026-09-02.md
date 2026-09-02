# WhereFilm performance pass — 2026-09-02

## Scope and method

This pass optimizes the latency a person can perceive while typing and searching. It does not claim that a seven-file fixture represents a multi-terabyte library. The PDF research report was treated as a source of hypotheses; the checked-out implementation, its tests, and measurements on this Mac were the source of truth.

The baseline binary is an immutable archive of `HEAD` (`c621b09`). The before and after binaries used the same database, vector index, bundled MobileCLIP S0 model, queries, and Mac. The baseline CLI received instrumentation-only `--benchmark-runs`; no search behavior was changed in that copy.

The fixture contains six real HEIC photographs and one 12-second Spanish interview: 7 assets, 9 moments, 9 embeddings, and 1 transcript chunk.

## 1. Baseline

| Metric | Before |
|---|---:|
| Interactive app query with Foundation Models, one measured run | 4.76 s wall |
| Visual search, warm p50 / p95 / p99 | 94.50 / 96.59 / 126.20 ms |
| Speech query, warm p50 / p95 / p99 | 94.55 / 98.44 / 103.88 ms |
| Filename query, warm p50 / p95 / p99 | 94.83 / 96.44 / 97.02 ms |
| Visual burst, 30 searches | 5.29 s wall; 3.20 s CPU; 159.5 MB max RSS |
| Index fixture | 15 jobs in 6.3 s; 99.5 MB max RSS |
| Tests | 60 passing |

The dominant hot-search cost was not HNSW. `SearchEngine` created and loaded a new `MobileCLIPTextEncoder` before every query, including filename-like identifiers. The app also waited for Foundation Models and the full visual ranking before publishing anything.

## 2. Changes implemented

### Progressive, cancellable search

- Problem: one blocking search produced one final snapshot; stale queries could consume work and the UI cleared useful feedback.
- Hypothesis: publish FTS/metadata first and visual fusion second, while generation IDs and task cancellation prevent stale writes.
- Implementation: `SearchEngine.searchProgressively` emits `fast` and `refined` snapshots. `AppModel` debounces typing by 90 ms, cancels the previous task, preserves the prior useful snapshot during refinement, and only shows a spinner after 300 ms without results.
- Files: `Sources/WhereFilmSearch/SearchEngine.swift`, `Sources/WhereFilmApp/AppModel.swift`, `Sources/WhereFilmApp/SearchView.swift`.

### Query-vector and model-lifetime cache

- Problem: the same 81 MB text encoder was constructed for every query.
- Hypothesis: a bounded process-local vector LRU plus a short model idle lifetime removes almost all repeated-query CPU without persistent state.
- Implementation: 128 vectors keyed by model version plus canonical phrases; encoder retained for 45 seconds after a miss; LRU eviction and model-version isolation are unit tested.
- File: `Sources/WhereFilmSearch/QueryEmbeddingCache.swift`.

### Intent fast path

- Problem: identifiers such as `SUNSET_0005` paid for visual encoding and returned unrelated visual neighbors.
- Hypothesis: filename/slate identifiers are literal metadata intent.
- Implementation: the deterministic planner emits no visual phrase when the query has no describable content.
- File: `Sources/WhereFilmSearch/QueryPlanner.swift`.

### Search priority and safe shared HNSW lifecycle

- Problem: search could reopen the same `VectorIndex` as a read-only mmap while the indexer held it for writes; background waves could start while the user was searching.
- Hypothesis: a writable graph is already searchable, and new background waves should yield to interactive work.
- Implementation: explicit fresh/read-only/writable modes prevent downgrading or discarding unsaved vectors. Interactive search priority is reference-counted; in-flight jobs finish, but no new wave starts until all overlapping searches end.
- Files: `Sources/WhereFilmML/VectorIndex.swift`, `Sources/WhereFilmIndex/Indexer.swift`, `Sources/WhereFilmIndex/ResourceGovernor.swift`.

### Searchable-before-enriched product state

- Problem: “indexed” hid the distinction between discovered, searchable, and deeply understood media.
- Implementation: the store now reports searchable, visual, transcript, OCR, and actively enriching asset counts. Coverage uses one aggregate pass per large table plus an indexed OCR asset count, instead of repeated full scans. The app and menu bar expose those states without asking the person to wait for 100% enrichment.
- Files: `Sources/WhereFilmCore/Database/IndexStore.swift`, `Sources/WhereFilmCore/Database/Schema.swift`, `Sources/WhereFilmApp/SearchView.swift`, `Sources/WhereFilmApp/MenuBarView.swift`, `Sources/WhereFilmCLI/WhereFilmCLI.swift`.

### Reproducible benchmarks

- `wherefilm search --benchmark-runs N` reports one cold run and warm p50/p95/p99 in the same process.
- `Benchmarks/spanish-search-v1.json` is a checked-in ground-truth dataset.
- `Scripts/benchmark-search.swift` reports Top-1, Recall@5, Recall@10, MRR, Top-5 overlap, and latency.

## 3. Benchmarks

Thirty in-process runs per route; one cold run is separated and the table compares the 29 warm runs.

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Visual stable p50 | 94.50 ms | 1.78 ms | -98.1% |
| Visual stable p95 | 96.59 ms | 2.12 ms | -97.8% |
| Visual stable p99 | 126.20 ms | 2.23 ms | -98.2% |
| Speech first useful p50 | 94.55 ms | 0.70 ms | -99.3% |
| Speech stable p50 | 94.55 ms | 1.15 ms | -98.8% |
| Filename stable p50 | 94.83 ms | 0.84 ms | -99.1% |
| Filename stable p95 | 96.44 ms | 1.14 ms | -98.8% |
| Filename result count | 7, including visual noise | 1 literal match | less noise |
| 30-query visual burst wall time | 5.29 s | 1.03 s | -80.5% |
| 30-query visual burst CPU time | 3.20 s | 0.38 s | -88.1% |

Cold visual startup is not solved. It varied from 1.19–1.40 s in baseline samples and 0.91–3.52 s after the change. This variance is dominated by first Core ML/model startup and system state; there is no defensible cold-start win in this dataset. Once the app is warm, the measured path is below the aspirational 50 ms first-useful and 250 ms stable budgets.

Across the 12-query benchmark with a fresh CLI process per query, deterministic latency was statistically noisy: p50 moved 103.5 → 98.9 ms, while p95 moved 624.3 → 683.9 ms. These numbers include process/model startup and should not be used to claim a regression or improvement. The in-process burst is the representative always-open app measurement.

Reproduction:

```bash
WHEREFILM_HOME=/path/to/fixture-home \
  .build/debug/wherefilm search \
  --database /path/to/fixture-home/index.sqlite \
  --no-llm --benchmark-runs 30 atardecer frente al mar

WHEREFILM_HOME=/path/to/fixture-home \
  swift Scripts/benchmark-search.swift \
  --binary .build/debug/wherefilm \
  --database /path/to/fixture-home/index.sqlite \
  --dataset Benchmarks/spanish-search-v1.json
```

## 4. Quality impact

The same deterministic dataset and index were used before and after.

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Top-1 consistency | 8/12 (66.7%) | 8/12 (66.7%) | 0 |
| Recall@5 | 12/12 (100%) | 12/12 (100%) | 0 |
| Recall@10 | 12/12 (100%) | 12/12 (100%) | 0 |
| MRR | 0.794 | 0.794 | 0 |
| Mean Top-5 overlap inside query clusters | 83.9% | 83.9% | 0 |

One Foundation Models baseline run produced the same Top-1 and Recall@5/10, MRR 0.819, and 100% Top-5 overlap. That modest ranking gain did not justify gating every keystroke behind a planner that measured in seconds. Foundation Models remains available to the CLI for experiments; the app's interactive path is deterministic.

This small fixture does not prove regional Spanish, slang, or typo robustness. It covers neutral Spanish, accent omission, colloquial phrasing, English, and English/Spanish mixing. A fixture with people, clothing, regional vocabulary, and typo pairs is still required before making those claims.

## 5. Resource impact

| Resource | Before | After | Interpretation |
|---|---:|---:|---|
| CPU, 30 visual queries | 3.20 s | 0.38 s | -88.1%; material battery/thermal proxy |
| Wall, 30 visual queries | 5.29 s | 1.03 s | -80.5% |
| Max RSS, same burst | 159.5 MB | 156.5 MB | -1.9%; effectively flat |
| Persistent disk | 0 new bytes | 0 new bytes | query cache is memory-only |
| Query-vector cache | none | at most ~256 KiB raw vectors plus dictionary overhead | bounded at 128 × 512 float32 values |
| Model lifetime | recreated per query | retained for 45 s after a miss | trades short idle residency for much less CPU |
| Index size | 9 embeddings | 9 embeddings | unchanged |
| Fixture indexing | 6.3 s / 99.5 MB | 6.7 s / 107.6 MB | one-shot noise; no throughput claim |

Battery energy was not measured with Instruments, so the CPU reduction is evidence of less work, not a direct battery-life percentage. The indexer still obeys existing thermal, power, foreground-editor, memory, and Vision crash ceilings.

## 6. Accepted trade-offs

- A new visual phrase still cannot cancel a synchronous Core ML invocation already in flight. Cancellation prevents stale publication and queued cancelled queries fail before encoding; at most one active encoding finishes.
- The text model may remain resident for 45 seconds after an uncached visual query. The measured burst RSS did not increase, but this intentionally favors active-search latency over immediate idle reclamation.
- One-character prefixes are ignored to prevent huge, low-value FTS fanout. Existing results remain visible until the second character.
- The app no longer waits for Foundation Models before searching. On the small benchmark Top-1 and Recall were unchanged, while one Foundation Models run had MRR +0.025. That possible lower-rank gain is traded for deterministic sub-frame text feedback.
- In-flight indexing work is not force-cancelled. New work pauses for search, avoiding unsafe interruption of media/Vision operations.

## 7. Rejected or deferred experiments

- **HNSW `efSearch` sweep:** not implemented. The pinned USearch Swift wrapper hardcodes `expansion_search` and exposes no supported public setter. Editing dependency checkout internals would make the benchmark unreproducible. HNSW and its persisted format remain unchanged.
- **More OCR workers:** rejected based on the repository's existing measured Vision ceiling and crash regression test. The research PDF's generic parallelism suggestion conflicts with the real macOS `VNRecognizeTextRequest` failure evidence in this project.
- **Foundation Models on the critical path:** measured in seconds and removed from the interactive app route. It remains an opt-in CLI experiment.
- **Alternative vector databases, cloud services, and wholesale re-embedding:** no local evidence supports their migration cost, and cloud processing violates the product's offline/privacy boundary.
- **Claiming an indexing speedup:** rejected. The only after run was 6.7 s versus 6.3 s before, within uncontrolled single-run variance and with no indexing hot-path change.

## 8. Next evidence-backed opportunities

1. Measure cold Core ML startup with 20+ isolated launches and signpost tokenizer load, model load, encode, HNSW, fusion, hydration, and thumbnail decode separately. Cold startup is now the visible tail.
2. Build a medium fixture with at least thousands of vectors before exposing/tuning HNSW search expansion. The current nine-vector fixture cannot locate the recall/latency knee.
3. Add a person/clothing fixture and grounded Guatemalan/Mexican/typo pairs. Current Recall@5 is strong, but Top-1 at 66.7% leaves ranking headroom.
4. Run “search while indexing” with 10,000 queued assets and collect UI frame pacing plus search p95. The safety/refcount behavior is tested, but large concurrent throughput is not yet measured.
5. Profile Energy Log and thumbnail first-paint in the signed app. CPU work fell sharply, but battery and first visual feedback need direct instruments.

## Validation gates

- `swift test`: 69/69 tests passed in 15 suites.
- Universal release build: `arm64` + `x86_64`, ad-hoc signature verified.
- Bundle smoke: 6/6 cases passed with bundled models, real photos, Spanish speech, scan/index/search/render, and honest empty results.
- Commit/push/notarization/publication: not performed; each remains a separate authorization and release gate.
