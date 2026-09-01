# 6. A resource governor, and honesty about what it can't do

**Status:** accepted · 2026-08-31

## Context

The requirement is "it should run all day and not bother DaVinci." That has to be
stated honestly first: **no AI analysis is free.** Two processes on one machine
share memory bandwidth, CPU, storage and accelerators. Nobody can promise that
indexing 30 TB is invisible.

What *can* be promised is that the indexer runs at minimum priority and gets out
of the way aggressively.

## Decision

**A small coordinator, disposable workers.** The app holds the database open and
a few tens of megabytes. Models are loaded when there is work, used in batches,
then released — the memory goes back to the system. Keeping the index
*searchable* does not require the image encoder to be resident; only a search
needs the text encoder, and only for milliseconds.

**Core ML pinned to `.cpuAndNeuralEngine`.** Deliberately excluding the GPU,
because that is what the editor is saturating and the ANE is usually idle. Not a
guarantee of zero contention — nothing is — but far more sensible than competing
for the same silicon.

**A governor consulted before every single job**, so Pause takes effect at the
next job boundary rather than at the end of a three-hour transcription queue:

| Signal | Response |
|---|---|
| `thermalState == .critical` | stop |
| `thermalState == .serious` | metadata only, concurrency 1 |
| Low Power Mode | metadata only |
| Resolve / Premiere / FCP / AE frontmost | stop |
| On battery | metadata only |
| Menu bar: Pause · 2h | stop, then resume by itself |

QoS is explicit per task: search is `.userInitiated`, scanning is `.utility`,
transcription is `.background`.

**Four independent levels of analysis**, so intelligence arrives gradually
instead of all at once: metadata (instant) → keyframes and embeddings (cheap) →
transcript and OCR (expensive) → diarization and faces (opt-in, not built).

## Consequences

**Good.** A new drive is partially searchable minutes after it is plugged in and
keeps improving quietly for hours. The menu bar switch drives a real governor,
not a cosmetic flag. Progress is reported honestly per level rather than as one
enormous "come back tomorrow" bar.

**Bad.** Smart mode is slower than it could be. Foreground-app detection is a
hardcoded bundle-ID list that needs updating as editors change identifiers.

## A note on the microphone

Indexing reads audio *tracks out of files on disk*. The microphone is never
opened, and `NSMicrophoneUsageDescription` is deliberately absent from
`Info.plist` — so macOS could not grant it even if something asked.

The menu bar switch therefore does not mean "stop listening to me." It means,
literally, pause the indexer.
