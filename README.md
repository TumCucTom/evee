# Evee

Evee is an Anima-native, local-first macOS voice workspace. Hold a shortcut,
speak, and release to insert polished text into any app. Record a meeting
without a bot, keep searchable dictations, meetings and memos on your Mac, and
let local agents query the workspace through MCP or the loopback API.

This is an independent implementation. Resonant Community Edition was used as
a behavioural reference; no Resonant source files or product assets are copied.

## What is implemented

- System-wide push-to-talk dictation and paste
- Local Parakeet v3 and Qwen3-ASR transcription through FluidAudio
- Deterministic punctuation, filler removal, vocabulary and per-app formatting
- Microphone meeting recording, live notes and local transcription
- Searchable local library for dictations, meetings and memos
- Personal dictionary and per-application writing styles
- Loopback JSON API with bearer authentication
- MCP helper exposing search and record lookup tools
- Optional HMAC-SHA256 meeting webhooks
- Privacy-safe defaults: no analytics, cloud processing or audio retention by default

Meeting capture records the microphone and the Mac's system audio through
separate local paths. If Screen Recording permission is unavailable, Evee says
so explicitly and continues in microphone-only mode.

## Requirements

- Apple Silicon Mac
- macOS 14+
- Xcode 16+
- Several gigabytes of free space for models

Parakeet v3 is the default (~735 MB). Qwen3-ASR requires macOS 15 and is roughly
1.75 GB. Model weights are downloaded from FluidInference repositories and keep
their own licences.

## Build

```sh
swift build
swift test
scripts/package_app.sh release
open dist/Evee.app
```

On first launch, grant Microphone and Accessibility permissions. Screen
Recording is only needed once system-audio meeting capture is enabled.

## Privacy

Evee stores content under `~/Library/Application Support/Evee/`. Long-term
audio retention, the local API, MCP registration and webhooks are opt-in.
Downloaded models stay in FluidAudio's local cache. No hosted service,
authentication system, analytics SDK or updater is configured.

## Design

The interface follows Anima's product system: paper `#FAFAFF`, ink `#211C2D`,
aubergine `#2F156D`, solid indigo `#4130E1`, and a restrained
magenta-to-electric-blue alpha gradient for one primary action at a time.
Recording remains semantically red; success, warning and danger never borrow
brand colour.
