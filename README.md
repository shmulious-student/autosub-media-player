# AutoSub Media Player

A cross-platform (**macOS + iOS**) personal media player whose killer feature is
**AI-generated, context-aware translated subtitles** — generated locally, for
free, with commercially-licensed models. It gets the things machine subtitles
usually get wrong: **gender, grammar, and character-name consistency**, by
building a per-title/franchise "character bible" and feeding it to the translator.

Subtitles are **pre-processed in the background** so playback is instant. Default
target language is **Hebrew** (RTL- and gender-aware), and any language is
selectable.

## How it works

- **macOS app = the hub.** Scans your library (local folders + SMB/NAS), enriches
  metadata from TMDB, builds character bibles, runs ASR (WhisperKit) + a
  context-aware translation LLM (DictaLM 3.0 for Hebrew, Qwen for others), and
  stores subtitle artifacts as portable `.srt`/`.ass` sidecars + an internal index.
- **iOS app = light companion.** Browses the library and plays video — streaming
  from the Mac/NAS over LAN, or from offline-pinned downloads — showing the synced
  subtitles. Artifacts sync via Bonjour/LAN (fast at home) and iCloud (remote).

Playback uses `media_kit`/libmpv for universal MKV/codec support on both platforms.

## Status

Greenfield. The agreed product + technical blueprint is in
**[docs/SPEC.md](docs/SPEC.md)**. Delivery is phased (v0 = single-title Mac
vertical slice → v1 usable Mac product → v2 iOS companion + sync → v3 iCloud/scale).

## Tech stack

| Layer | Choice |
|---|---|
| App shell / UI | Flutter (macOS + iOS) |
| Playback | media_kit / libmpv (playback-only, commercial-safe build) |
| ASR | WhisperKit (MIT) + forced-alignment refinement |
| Translation | DictaLM 3.0 (Hebrew, Apache-2.0) · Qwen3/Qwen-MT (other langs, Apache-2.0) |
| Inference runtime | MLX (Apple Silicon) / llama.cpp (GGUF) |
| Mac engine | Native Swift sidecar daemon (loopback IPC + Bonjour server) |
| Store | SQLite (source of truth) + portable subtitle sidecars |
| Metadata | TMDB |
| Sync | iCloud (CloudKit) + Bonjour/LAN |

## License

Commercial — dependencies are constrained to permissive licenses (no NLLB/Aya/GPL).
