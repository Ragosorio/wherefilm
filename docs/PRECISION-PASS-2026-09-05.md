# Precision pass — 2026-09-05

What was built against [`PLAN-02`](PLAN-02-PRECISION-PERSONAS-INTEL.md), what it
measured, and what it failed to prove. All nine phases landed; the numbers below are the ones that survived being
measured properly, which is not all of the ones that were hoped for.

## How anything here is measured

`wherefilm eval` runs a labelled set through the real engine and reports
Recall@10/@50, MRR, nDCG@10, the false-positive rate on negative cases, and a
calibration table. The set is
[`Benchmarks/quality-v1.json`](../Benchmarks/quality-v1.json): 58 cases — 50
positive, 8 negative — over the 43-asset library built by
[`Scripts/make-eval-library.swift`](../Scripts/make-eval-library.swift).

**Two rules, both learned the hard way.**

Quality is never measured on `bench-fixture`. That catalog synthesises
embeddings at a chosen cosine distance; it measures latency, memory and scaling
and nothing else.

Quality is measured with `--no-llm`. Apple's on-device planner is
non-deterministic, and three identical runs of one build gave:

| run | MRR | nDCG@10 | Recall@10 |
|---|---|---|---|
| 1 | 0.832 | 0.833 | 86% |
| 2 | 0.811 | 0.835 | 86% |
| 3 | 0.856 | 0.851 | 86% |

That spread is wider than most of the improvements anyone would want to claim.
Recall@10 was stable; MRR and nDCG were not. Anything below quoted as a delta
was measured deterministically.

## What each phase actually did

### 7 · The evaluation harness

There was no way to measure recall before this. `wherefilm eval`, the labelled
set, and a library with real distractors — 26 photographs whose content Apple's
own names describe, 12 abstract wallpapers that exist to be wrong answers, 3
rendered cards with exactly known text, 2 Spanish narrations from `say`.

Baseline: **Recall@10 86% · MRR 0.837 · nDCG@10 0.818 · 25% of negatives
returned something**, and a calibration table where the 80–89% bucket was right
33% of the time.

### 8 · Ranking, filters and the Spanish half

Four changes. Three are bug fixes and one is new capability.

- `mediaType` and `dateRange` had been computed since the first version and
  never read. Applied now, and only from words that cannot mean anything else —
  a bare month name is not a date, which cost one case its rank to learn.
- Min–max normalisation gave a channel holding one candidate a perfect 1.0.
  Replaced by absolute per-channel confidence combined as a noisy-OR, which
  also retires the `agreementBonus` that let two mediocre signals display 100%.
- `Translation.framework` became the Spanish tier. Offline, unlimited
  vocabulary, and present on Macs with no Apple Intelligence.
- CLIP caption templates, applied only to the translated tier.

On the path without the on-device model — which is every Intel Mac — nonsense
queries that returned something fell from **88% to 38%** and nDCG went from
**0.801 to 0.834**. With the model available the deltas were inside the noise
band above.

Two experiments are in the tree as measured dead ends: rank fusion (RRF at
k=60/10/3, all worse than absolute confidence at this size) is a selectable
mode, and judging visual hits by z-score against the library's own distribution
is off by default — it needs a library big enough for a distribution to mean
something.

### 9 · Intel

macOS 26 is the last release that runs on Intel. `MachineProfile` asks the
machine what it is instead of inferring it from core counts; `ComputePolicy`
takes the GPU when nobody needs it and yields it the moment an editor opens.

The finding that mattered came from running the x86_64 slice:
`SpeechTranscriber.isAvailable` is **false in an x86_64 process**, so on a real
Intel Mac it is absent. `DictationTranscriber` — Apple's documented fallback —
carries the same `audioTimeRange` attribute, and produced correct timestamped
Spanish through Rosetta. Migration v5 records which engine wrote each chunk, so
a library transcribed by the weaker one can be found and redone later.

Simulated Intel quality: **Recall@10 85% · nDCG 0.864**, against 87% / 0.869 on
Apple silicon.

### 10 · Vision out of process

`RecognizeTextRequest` corrupts memory above ~3 concurrent requests, which
capped all Vision work in the process at two. Helper processes escape that
because the fault is per-process. Measured over 60 text-heavy pages:

| | time |
|---|---|
| in-process, gate of 2 | 17.7 s |
| 2 helpers | 14.9 s |
| 3 helpers (default here) | **12.6 s** |

All configurations produced byte-identical OCR — 60 rows, 78,950 characters —
which is also the answer about the JPEG handoff between processes.

### 11 · Scene labels

`ClassifyImageRequest` on frames that are already decoded, indexed as text so
the translator makes it work in Spanish.

**Neutral on this fixture, and the fixture is the reason.** A classifier puts
`sky` and `outdoor` on most of a landscape library; admitted plainly it
promoted thirty files equally for "nubes en el cielo" and cost seven cases their
rank. Weighting each label by how rare it is *in this library* brings it back to
parity. Whether it helps has to be measured on an archive that contains ducks,
microphones and dogs — 26 landscape photographs contain none of them.

### 12 · Reranking with a stronger model

S2 over the forty thumbnails the preview cache already wrote. ~110 ms, no
original reopened.

**It does not pay yet:** nDCG 0.855/0.856 without it, 0.840/0.840 with it, two
deterministic runs each. The suspected cause is written next to the constants
that cause it — `similarityFloor` and `similarityCeiling` are S0's numbers, and
a better model judged on another model's scale is not obviously better at
anything. Off by default; one flag for whoever re-measures.

### 13 · People

Detection, quality gating, cropping, embedding behind a `FaceEmbedder`
protocol, online clustering, an offline consolidation pass, naming, merge,
split, appearances as intervals, and erasure. See
[ADR 7](decisions/0007-faces-reversed.md) for why the original exclusion was
reversed and what makes that acceptable.

**A real model, and still unverified end to end.** Vision exposes no identity
embedding, so the descriptor comes from outside: `Scripts/fetch-face-model.sh`
installs AuraFace, a ResNet-100 ArcFace model published under **Apache-2.0** —
chosen over the better-known InsightFace and EdgeFace weights precisely because
those are research-only, and this app already carries one research-licensed
model in MobileCLIP. Without it the pipeline falls back to Vision's general
feature print, which is not face recognition and says so in `doctor`.

Verified about the model: correct tensor layout (1×3×112×112, channels first,
−1…1, half precision — which is how a fatal `Float16` mismatch was caught), 512
unit-length dimensions, deterministic for identical pixels, discriminating
between different ones.

**Then measured on real faces.** `Scripts/fetch-face-fixture.sh` downloads
freely licensed photographs of public figures from Wikimedia Commons — several
per person, across years and photographers. Three things were wrong:

| | same p50 | different p50 | F1 |
|---|---|---|---|
| padding 0.00 | 0.404 | 0.272 | 0.579 |
| padding 0.15 | 0.511 | 0.326 | **0.647** |
| padding 0.35 (was) | 0.492 | 0.363 | 0.512 |

Eye alignment trades a little F1 for **precision 1.00 against 0.89**, which is
the trade worth making: a person split across two clusters is one click to fix,
two people merged into one is a wrong answer nobody notices. Thresholds follow
from the same distributions — joining at 0.45, consolidating at 0.50, where 0.40
collapses purity from 96% to 69%.

End to end: **26 faces of four people → 16 groups, 96% purity**, one impure
group holding one face each of two people. Naming one group and searching for it
returns their photographs at 100% with `person` evidence, and the name survives
two typos: `people where "Barak Obana"` finds Barack Obama.

### 14 · Voices

Built after the objection below was raised and overruled, which is the right
order: the concern was real and the decision was the user's.

FluidAudio is a new external dependency (Apache-2.0 SDK, CC-BY-4.0 pyannote
weights), it is published for Apple silicon only, and its models are fetched
from Hugging Face — a network request in an app whose premise is that there are
none. All three costs are handled by making them explicit rather than hiding
them: `wherefilm voices install` is a command a person runs, indexing never
reaches for the network on its own, and on a Mac without a neural engine the
capability reports itself absent and nothing else changes.

It compiles and links for x86_64, so the universal build is intact.

Verified end to end on the two narrated videos: each produced one speech
segment and one speaker, correctly, and the two segments — the same synthetic
voice in two different files — **clustered into a single voice**. That is the
part that matters: a diarizer's "Speaker 1" means nothing across files, and
clustering the embeddings is what turns forty unrelated speakers into one
person.

Voice appearances land in the same `person_appearances` table faces write to,
so "¿dónde sale Jorge?" and "¿dónde habla Jorge?" are one query. Linking a
voice to a face is *proposed* from how much time they share on screen and
confirmed by a person, like every other identity decision here.

### 15 · Learning, and getting out of the way

- **Learning is off by default** and does nothing below two hundred recorded
  interactions. It multiplies *ordering* weights only, so it can change which
  result appears first and can never change what the interface claims about it.
  `wherefilm usage` shows, enables, disables and erases it.
- **The sidecar moves a drive's knowledge between Macs.** Verified end to end,
  including across architectures: a catalog exported from the arm64 build
  imported into the x86_64 build and answered the same queries, with the
  original media never read. 43 assets, 47 moments, 122 labels and 2
  transcripts travelled in 360 KB. Face vectors, usage history and security
  bookmarks are excluded, and a test asserts it.
- **Disk work is throttled** with `IOPOL_THROTTLE`, scoped to synchronous work
  and never held across an `await`.
- **An indexing window** exists, because "only between 11 pm and 7 am" is what
  people with large archives actually want.

Quality after all of it, deterministic: **Recall@10 86% · MRR 0.823 ·
nDCG@10 0.853**, unchanged from before the phase.

## The shape of the result

| | before | after |
|---|---|---|
| Recall@10 (Apple silicon) | 86% | 86–87% |
| Recall@10 (no on-device model) | 85% | 86% |
| Negatives answered, no model | 88% | 38% |
| nDCG@10, no model | 0.801 | 0.853 |
| OCR throughput | 17.7 s | 12.6 s |
| Can answer "¿dónde sale Jorge?" | no | yes, unverified |
| Can move an indexed drive to another Mac | no | yes, verified |
| Runs on Intel | untested | verified through Rosetta |
| Nonsense queries that answer anyway | 38% | 12% |
| Face recognition model | none | AuraFace, Apache-2.0 |
| Can answer "¿dónde habla Jorge?" | no | yes, verified on narration |

The recall number barely moved, and that is the honest headline. What moved was
everything around it: false positives on the path most Macs will take, a
calibration that no longer claims 90% for coin flips, an indexer that is 1.4×
faster and no longer takes the app down when Apple's OCR fails, and a set of
capabilities — people, portability, Intel — that did not exist.

## What to do next, in order

1. **Measure on Manu's real material.** Every "neutral" verdict above is
   neutral *on 43 landscape photographs*. Labels, reranking and faces are all
   waiting on an archive with people and things in it.
2. **Run face recognition on Manu's footage.** It is now measured on 26 faces of
   four public figures; what nobody has measured is whether it groups *his*
   people correctly, on material with motion blur, profiles and bad light.
3. ~~Re-measure the S2 rerank with S2's own calibration.~~ Done, and the answer
   was no: `wherefilm calibrate` shows S0 and S2 separating right from wrong
   answers almost identically (medians 0.191/0.133 against 0.177/0.122), so the
   second opinion has little to add. The same measurement did find the visual
   floor was too low, and raising it from 0.14 to 0.18 halved the false
   positives.
4. **Try speaker analysis on a real interview.** It is verified on synthetic
   narration, where one voice is genuinely one voice. Two people talking over
   each other is the case that decides whether the thresholds are right.
