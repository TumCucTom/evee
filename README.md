# Evee

Evee is an Anima-native, local-first macOS voice workspace. Hold a shortcut,
speak, and release to insert polished text into any app. Record a meeting
without a bot, keep searchable dictations, meetings and memos on your Mac, and
let local agents query the workspace through MCP or the loopback API.

The current draft PR is a hardened alpha, not yet a production-ready release.
The exact acceptance gates and remaining product work are tracked in
[`docs/PRODUCT_RELEASE_GATES.md`](docs/PRODUCT_RELEASE_GATES.md); compiling or
matching a tool name is not treated as functional completeness.

## What is implemented

- System-wide push-to-talk dictation and paste
- Local Parakeet v3 and Qwen3-ASR transcription through FluidAudio
- Deterministic punctuation, filler removal, vocabulary and per-app formatting
- Microphone meeting recording, live notes and local transcription
- FTS5-indexed local library for dictations, meetings and memos
- Personal dictionary and per-application writing styles
- Loopback JSON API with bearer authentication
- MCP helper exposing search and record lookup tools
- Optional HMAC-SHA256 meeting webhooks
- Privacy-safe defaults: no analytics or cloud processing; dictation and meeting
  audio retention is off by default, while memo audio is retained for playback

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

Release automation sets `EVEE_VERSION` and `EVEE_BUILD_NUMBER` so the app's
bundle metadata matches the published artifact. Local packages default to the
current development version; both values can be overridden for candidate
verification.

On first launch, grant Microphone and Accessibility permissions. Screen
Recording is only needed once system-audio meeting capture is enabled.

`package_app.sh` produces an ad-hoc-signed development build. A distributable
release requires an Apple Developer ID identity and a `notarytool` keychain
profile:

```sh
EVEE_CODESIGN_IDENTITY='Developer ID Application: …' \
EVEE_NOTARY_PROFILE='evee-notary' \
scripts/release_app.sh
```

That path signs with the hardened runtime, creates a DMG, submits it to Apple,
staples the ticket, runs Gatekeeper assessment and writes a SHA-256 checksum.
The repository does not contain signing credentials.

Maintainers can also run the manual `notarized-release` GitHub workflow after
configuring the `EVEE_CERTIFICATE_P12`, `EVEE_CERTIFICATE_PASSWORD`,
`EVEE_KEYCHAIN_PASSWORD`, `EVEE_APPLE_API_PRIVATE_KEY`,
`EVEE_APPLE_API_KEY_ID`, and `EVEE_APPLE_API_ISSUER_ID` repository secrets.

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
