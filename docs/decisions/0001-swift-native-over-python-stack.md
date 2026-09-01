# 1. Swift and Apple frameworks, not a Python/Docker stack

**Status:** accepted · 2026-08-31

## Context

The reference implementations for this kind of product all converge on the same
stack: Python, FastAPI, a JavaScript front end, and a vector database in Docker.
`openara-ai/media-search-agent` uses Python + FastAPI + React + Tauri + Qdrant;
Fennec Search needs Docker, PostgreSQL 16 with pgvector, Vue, and roughly 10 GB
for its stack and models.

That works for a home server. It is close to the opposite of what this product
needs to be: a utility that sits quietly in the menu bar next to DaVinci Resolve
all day and is invisible until you ask it something.

## Decision

Swift, SwiftUI and Apple's own frameworks, with no Python runtime, no Docker, no
Electron and no server process.

- **AVFoundation** — container inspection and keyframe extraction
- **Vision** — on-screen text
- **Core ML** — the image/text encoders, pinned to CPU + Neural Engine
- **Speech** — `SpeechAnalyzer` / `SpeechTranscriber`, whose model the OS manages
- **FoundationModels** — optional query understanding
- **FileManager / FSEvents / security-scoped bookmarks** — storage and permissions

Swift's C++ interoperability keeps the door open for `whisper.cpp` or similar
without dragging in an interpreter.

## Consequences

**Good.** The whole app is one binary of a few megabytes. Nothing has to be
installed before it runs. `.cpuAndNeuralEngine` keeps the indexer off the GPU
that the editor is already saturating. Speech models are system-managed, so they
inflate neither the bundle nor the app's resident memory.

**Bad.** macOS 26+ only. Intel Macs run the same universal application through
the native `x86_64` slice, but visual inference falls back to CPU when no Neural
Engine is present and is therefore slower. No reuse of the Python ecosystem — a
new model means a `coremltools` conversion step. Fewer people can contribute to
a Swift codebase than to a Python one.

**Accepted.** The target is one person's Mac, not a fleet.
