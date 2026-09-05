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
from outside. The candidates (EdgeFace, ArcFace) are research-licensed
conversions somebody has to install, and requiring that before any of this
worked would have meant building the pipeline blind.

So the pipeline is built against a `FaceEmbedder` protocol and ships with
`VisionFeaturePrintEmbedder`, which uses `GenerateImageFeaturePrintRequest`.
**That is not a face recognition model.** It describes pictures in general: two
photographs of the same person in different light can score lower than two
strangers photographed in the same room. It groups near-duplicates well and
distinguishes people poorly.

It is here because it makes everything around it real — cropping, quality
gating, clustering, naming, merging, splitting, appearances and erasure are all
implemented and tested against it — and because every vector records its
`modelID`. Installing a proper model later changes that string, stops the old
vectors from ever being compared with the new ones, and turns the same code into
face recognition. That is the same mechanism `embeddings.modelID` has always
used for the visual model, applied to the one place it matters even more.

## What is not verified

Detection quality end to end. The evaluation library is 43 photographs of
landscapes and rendered text, and it verifies exactly one thing about faces:
that none are found in it, which is the correct answer. Vision's detector cannot
be exercised by synthetic faces — drawn ones are not detected at all, measured —
so the honest position is that the clustering logic is tested and the recognition
quality is unmeasured until it runs on real footage of real people.

## Licence, if this ever stops being a gift

EdgeFace is CC BY-NC-SA 4.0 and InsightFace's models are non-commercial. That
does not change the situation the app is already in — MobileCLIP is
research-licensed under `apple-ascl` — but it fixes it: a commercial version
would need to replace *both* models. Both are behind an abstraction with a
`modelID`, so that is a reindex, not a rewrite.
