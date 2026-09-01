# 5. Fuse several cheap signals instead of asking one model to understand everything

**Status:** accepted · 2026-08-31

## Context

*"The interview where the guy had a blue shirt and talked about the budget"*
mixes two completely different questions: what the picture looked like, and what
was said. A video-language model could in principle answer both, but SentrySearch
— which does exactly that — recommends an 8B model for Macs with 24 GB or more,
and estimates ~6 GB of memory for the 2B variant. For something meant to sit
quietly beside Resolve on a 16 GB machine, that is the wrong shape entirely.

## Decision

Four independent channels, fused afterwards:

| Channel | Index | Answers |
|---|---|---|
| visual | MobileCLIP → USearch | what the frame looked like |
| transcript | FTS5 | what was said, and when |
| on-screen text | FTS5 over Vision OCR | signs, badges, slates, screens |
| metadata | FTS5 | filenames, folders, camera |

Signals from **different** channels landing within 30 s of each other in the same
file merge into one moment and earn a corroboration bonus. Signals from the *same*
channel do not merge — two visual hits 25 s apart are two different moments of one
interview, and collapsing them would hide results while manufacturing confidence.

Visual scores are calibrated **absolutely**, not by rank. Measured on this
hardware with real photographs: correct answers land at cosine 0.177–0.258,
plausible-but-wrong at 0.13–0.21, and a deliberately absurd query ("a plate of
spaghetti" over landscape photos) tops out at 0.099. Anything below 0.12 is
discarded. Text channels use bm25, whose absolute value means nothing, so those
are rank-normalised.

Every result carries its evidence. Never a bare `91%`; always *which* signal
fired, and with what text.

## Consequences

**Good.** A query with no visual match returns nothing from that channel instead
of confidently returning the best of nine bad guesses — which is the failure mode
that destroys trust in a search tool. Two mediocre signals that coincide in time
beat one strong signal alone. When the answer is slightly wrong, the evidence
lines explain why, which usually makes it useful anyway.

**Bad.** The similarity floor is model-specific and has to move with the model
(it lives on `MobileCLIPVariant`, not on the search engine). Channel weights are
hand-tuned: 0.45 visual, 0.35 transcript, 0.12 OCR, 0.08 metadata.
