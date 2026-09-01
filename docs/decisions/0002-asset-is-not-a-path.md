# 2. An asset's identity is its content, never its path

**Status:** accepted · 2026-08-31

## Context

The obvious key for a media file is where it lives. It is also wrong in every
way that matters:

- Footage gets reorganised. `Entrevistas/` becomes `Archive/2025/`.
- macOS remounts volumes under different paths — Peakto's own support
  documentation covers `/Volumes/Media` reappearing as `/Volumes/Media 1`.
- The same clip legitimately exists on an SSD, a backup drive and a NAS at once.
- Apple documents that `fileResourceIdentifier` does **not** survive a reboot,
  and `fileContentIdentifierKey` is APFS-only — useless on exFAT or a NAS.

Hashing 30 GB per file would make the first scan of a few hundred terabytes a
multi-day I/O job, so a full checksum can't be the answer either.

## Decision

Two tables, and two tiers of identity.

`assets` holds what we learned. `locations` holds where the file might be, keyed
by `(volume UUID, path relative to the volume root)`. One asset, many locations.

- **Quick key** — SHA-256 over `size ‖ duration ‖ codec ‖ head 1 MiB ‖ middle
  1 MiB ‖ tail 1 MiB`. Milliseconds, and never touches the middle 30 GB.
- **Strong key** — full-stream hash. Computed only on ambiguity, and only when
  the machine is idle.

Volume UUIDs come from `volumeUUIDString`, so a remount changes nothing.

## Consequences

**Good.** Moving a file rebinds it silently. The same footage on three drives is
one asset with three locations, not three duplicates. Unplugging a drive marks
its files `offline`; a deleted file becomes `missing` — and in both cases the
transcript, the embeddings and the previews are all still there. *Even if it gets
deleted, we don't lose what we knew about it.*

**Bad.** Quick keys are not cryptographic proof. Two files could in principle
collide; the strong key exists for exactly that case. Every path lookup is one
indirection deeper.
