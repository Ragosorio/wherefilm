# 7. Face recognition, reversed

**Status:** accepted · 2026-09-05 · supersedes the exclusion in
[`PLAN.md` §7](../PLAN.md) and the closing note of
[`RESEARCH-NOTES.md`](../RESEARCH-NOTES.md)

## What the first version decided

Face recognition was deliberately left outside the product:

> Reconocimiento facial **fuera del núcleo**: implica datos biométricos y
> obligaciones legales/de consentimiento, y *"el chavo de playera azul"* se
> resuelve sin saber quién es.

That reasoning was sound, and one half of it is still true: identity is
biometric data, and adding it brings obligations that a search index does not
otherwise have.

## Why it is being reversed

The other half was wrong about the archive this is for. "El chavo de playera
azul" is how somebody describes a person they *cannot* name. Most of the time
they can:

> ¿dónde aparece Jorge Álvarez? ¿en qué minuto sale?

There is no way to answer that from appearance, dialogue, on-screen text or
metadata. A blue shirt is not a person, and the same person in a different shirt
is a different query. Either the system learns who Jorge is, or that question —
the most natural question anybody asks of an archive of people — has no answer
at all.

So the decision changes, and the obligations come with it.

## What makes it acceptable

Not promises. Structure.

1. **Off unless asked for.** `wherefilm index --faces`. No face is detected, no
   crop is made and no vector is computed until somebody turns it on. It is the
   only analysis in the pipeline that is a decision rather than a default.

2. **One file writes it.** `PeopleStore.swift` is the only place face and person
   rows are created or changed, and they live in their own tables.

3. **Erasure is narrow and provable.** `wherefilm people forget --yes` deletes
   every face vector, person, name, correction and appearance, and touches
   nothing else. A test asserts that afterwards the library still holds its
   assets, moments, transcripts and on-screen text, and still answers the
   searches it answered before. Biometric data that cannot be removed on demand
   should not be collected, so the button exists before the feature does.

4. **A name is only ever set by a person.** Clustering produces "these look like
   the same person" and stops there. An unnamed cluster is useful and anonymous;
   a name is an act somebody performs. Nothing infers a name from OCR — a badge
   that reads "JORGE ALVAREZ" may *suggest* one, and suggesting is where it ends.

5. **Corrections outlive the machine.** A merge, a split and a name are recorded
   in `people_feedback`, and the automatic consolidation pass reads them before
   it does anything: two named clusters are never merged, and a split is
   permanent. The only thing worse than a wrong cluster is a wrong cluster that
   comes back after being corrected.

6. **Nothing leaves the Mac,** which was already true of everything else, and
   the optional sidecar deliberately does not carry face vectors: a drive lent
   to somebody should not carry the biometrics of everyone who was ever filmed.

## The state of the model

Vision detects faces and exposes no identity embedding — the whole request list
in macOS 26 has nothing that returns a faceprint — so the descriptor has to come
from outside. The pipeline is therefore built against a `FaceEmbedder` protocol,
and there are two implementations.

**`CoreMLFaceEmbedder` — AuraFace, and what to use.** A ResNet-100 trained with
ArcFace's additive angular margin loss, published by fal under **Apache-2.0**
and trained on commercially available data specifically so it can be used
commercially. `Scripts/fetch-face-model.sh` installs it; 125 MB compiled.

That licence is why it was chosen over the better-known options. InsightFace's
own weights and EdgeFace are research-only, and this app is already research-only
because MobileCLIP is. A *second* non-commercial model would have made that
permanent. An Apache-2.0 one leaves exactly one thing to replace if this ever
stops being a gift.

**`VisionFeaturePrintEmbedder` — what happens without it.** The pipeline still
runs, grouping faces with `GenerateImageFeaturePrintRequest`, and **that is not
a face recognition model.** It describes pictures in general: two photographs of
the same person in different light can score lower than two strangers
photographed in the same room. It groups near-duplicates well and distinguishes
people poorly. `wherefilm doctor` says which one is in use, in those words.

Both record their `modelID` with every vector, so installing the real model
after the fact is a background reindex and never a comparison between
incompatible vectors — the same mechanism `embeddings.modelID` has always used
for the visual model, applied to the one place it matters even more.

## What is not verified

Recognition quality end to end. The evaluation library is 43 photographs of
landscapes and rendered text, and it verifies exactly one thing about faces:
that none are found in it, which is the correct answer. Vision's detector cannot
be exercised by synthetic faces — drawn ones are not detected at all, measured —
so there is no way to measure accuracy here without real footage of real people.

What *is* verified about the model: it loads, its tensor layout is right
(1×3×112×112, channels first, −1…1, half precision, all asserted), it returns
512-dimensional unit vectors, it is deterministic for identical pixels, and it
does not return the same vector for different ones — which is exactly what a
mis-shaped tensor looks like, and how the half-precision bug was caught.

## Licence, if this ever stops being a gift

One thing to replace, not two. MobileCLIP is research-licensed under
`apple-ascl`; AuraFace is Apache-2.0 and FluidAudio's SDK is too (its pyannote
weights are CC-BY-4.0, which requires attribution and permits commerce). So a
commercial version needs a different *visual* model and nothing else — and since
that model sits behind an abstraction with a `modelID`, swapping it is a
background reindex rather than a rewrite.
