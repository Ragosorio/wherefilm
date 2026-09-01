# 4. MobileCLIP v1 now, with the Spanish gap closed in the query

**Status:** accepted · 2026-08-31

## Context

The research proposed MobileCLIP2. Checking the actual model hub changed the
plan: Apple publishes MobileCLIP2 (S0/S2/S3/S4/B/L-14) as **PyTorch/OpenCLIP
only**. The repository with official Core ML exports, `apple/coreml-mobileclip`,
contains **MobileCLIP v1** — `s0`, `s1`, `s2`, `blt` — and nothing else.

Read straight from the Core ML protobuf: image encoder takes RGB 256×256 and
returns `[1, 512]` float32; text encoder takes `[1, 77]` int32 and returns
`[1, 512]`.

MobileCLIP v1 is an English model, and its tokenizer says so out loud. Verified
against `openai/clip-vit-base-patch32`:

```
"man wearing a blue shirt"          → [49406, 786, 3309, 320, 1746, 2523, 49407]
"hombre con camisa azul, de noche!" → [49406, 906, 7782, 2457, 1004, 6536, …]
```

*man* is one token. *hombre* is `hom` + `bre</w>`.

SigLIP 2 Base is explicitly multilingual and Apache-2.0, but heavier. Jina CLIP
v2 covers 89 languages but is ~0.9B parameters under CC BY-NC — fine for
benchmarking, awkward if the product ever stops being personal.

## Decision

Ship **MobileCLIP-S0 v1** as the default, and fix the language gap in the *query*
rather than in the model. Three tiers, each degrading cleanly:

1. **Apple Foundation Models** (on-device, when Apple Intelligence exists) —
   structured output splitting a query into a visual phrase in English and spoken
   terms in the original language.
2. **A built-in Spanish→English lexicon** of ~300 audiovisual terms.
3. **The query as typed.**

The spoken half is **never** translated: the transcript is in the language that
was actually spoken.

The LLM's output is treated as strictly *additive* — its terms are merged with
the raw query's words, never substituted for them. In testing it translated
"presupuesto" to "budget" despite explicit instructions not to; because the
original word is always kept, the search still worked. The optional component
can improve the result; it cannot break it.

## Consequences

**Good.** No multi-gigabyte multilingual model. The visual encoder is 22 MB
compiled. Every embedding records its `modelID`, so moving to MobileCLIP2 or
SigLIP 2 is a background reindex, not a migration. The app is fully functional on
Macs with no Apple Intelligence.

**Bad.** Recall in Spanish depends on the quality of the translation step.
MobileCLIP2 and SigLIP 2 need a local `coremltools` conversion before they can be
offered. The lexicon needs hand-maintenance.

**Open.** Measure recall on Manu's real archive, 50 queries in both languages, and
let that decide whether SigLIP 2 is worth the extra weight.
