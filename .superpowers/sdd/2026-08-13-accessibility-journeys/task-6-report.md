# Task 6 report — atomic meeting speaker projections

## Scope

- Issue: TOM-49.
- Context head: `95bf7254500ba62011741d00b98112e15bc82c27`.
- Implemented canonical speaker relabelling for timed meeting segments and the
  transcript, raw transcript, extractive intelligence, search, export, public
  API, and helper projections.
- Kept the work limited to existing diarization and local extractive
  intelligence. No new identification, diarization, or summarization behavior
  was added.

All executable checks used synthetic records and temporary library roots. No
real Evee workspace, recording, model, API credential, or client configuration
was read or changed.

## RED

- Added `meeting-relabel` executable coverage plus focused XCTest sources for
  diarized cluster updates, channel-only updates, whitespace normalization,
  chronological rebuilding, missing IDs, source immutability, search, export,
  and public projections.
- `swift run evee-core-checks --filter meeting-relabel` failed before production
  implementation because `MeetingRecordProjection` and
  `MeetingRecordProjectionError` were absent.
- The first implemented run then failed the intelligence equality assertion.
  Root-cause tracing showed that the extractive pipeline emitted fresh random
  evidence IDs on every run, so identical timed segments could not produce an
  equal projection.

## Implementation

- `MeetingRecordProjection.relabel(record:segmentID:label:)` now returns a new
  record, preserving the input value. It trims labels, turns whitespace-only
  values into `nil`, relabels every diarized segment in the selected prior
  cluster, and limits channel-attributed edits to the selected segment.
- The projection orders segments chronologically, rebuilds speaker-prefixed
  `text` and `rawText`, advances `updatedAt`, and regenerates local extractive
  meeting intelligence from the same segments and timestamp.
- Extractive topic and insight IDs now use their source segment IDs. This makes
  the pre-existing deterministic extraction stable across projection rebuilds
  without changing its conclusions or evidence.
- The record detail timeline routes edits through the canonical projection and
  explains that relabelling rebuilds the transcript and meeting overview.
- The existing app save path still performs exactly one `LibraryStore.upsert`.
  It preserves a timestamp already advanced by the projection, commits the
  record and search projection before publishing the changed in-memory record.
- Markdown export and the API/helper `PublicWorkspaceRecord` already consume
  the changed canonical record, so no special export or transport mutation was
  introduced; the executable check covers both boundaries.
- Removed the unmodified Return shortcut from meeting Stop, allowing Return in
  Live Notes to insert a newline. The privacy-settings button is now a separate
  accessibility element from the combined recording-status description.

## Verification

| Command | Result |
| --- | --- |
| `swift run evee-core-checks --filter meeting-relabel` | Passed after the red/green cycle. Covers record, intelligence, durable search, Markdown export, and shared API/helper public projection. |
| All 35 explicit `evee-core-checks` filters | Passed serially, including `meeting-relabel`, `public-record`, `mcp-public-output`, all API/webhook/lifecycle/audio/recovery filters, and accessibility filters. |
| `swift build --target EveeCore --jobs 2` | Passed. |
| `swift build --target EveeMCP --jobs 2` and `swift build --product evee-mcp --jobs 2` | Passed. |
| Direct `swiftc -typecheck` of every `Sources/EveeApp` Swift file against the built package modules | Passed. |
| `swift build --target EveeApp --jobs 2` | Blocked before EveeApp compilation because KeyboardShortcuts previews cannot load `PreviewsMacros` under the active Command Line Tools SDK. |
| `swift test --filter MeetingRecordProjectionTests` | Blocked before test execution: the active Command Line Tools SDK has no importable `XCTest` module and cannot load KeyboardShortcuts' `PreviewsMacros`. |
| `swift test --filter WorkspaceSearchTests --jobs 1` | Blocked before test execution by the same unavailable preview macro plugin. |
| `git diff --check` | Clean. |

## Toolchain boundary

- `xcode-select -p` reports `/Library/Developer/CommandLineTools`.
- No `/Applications/Xcode*.app` installation is present.
- Full-Xcode XCTest and normal SwiftPM app-target results are therefore not
  claimed. The direct app source typecheck and executable synthetic checks cover
  the changed code available under this host toolchain.
