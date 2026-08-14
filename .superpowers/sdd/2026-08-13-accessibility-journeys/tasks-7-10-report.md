# Tasks 7–10 report — workspace and privacy parity

Issue: TOM-49

Baseline: `ac20060`

Scope: task briefs 7–10 only

## Outcome

The final bounded parity cycle adds four narrowly scoped user-visible guarantees:

1. Evee applies AppKit's best-effort window sharing exclusion to its main,
   menu-bar, Settings, and capture HUD windows. A session-only privacy mode
   branches before the workspace or Settings roots are constructed, leaving
   only neutral privacy copy and an accessible way to turn the mode off.
2. Workspace search now returns the snippet produced by the matching FTS5
   column and indexes canonical title, finished/raw text, notes, tags, source
   application, permitted context, segment labels/text, meeting insights, and
   memo insights. The versioned projection rebuilds once from canonical JSON
   after an actual SQLite open/prepare/step failure, then retries once.
3. Retained-audio export copies to an owner-only sibling staging file, verifies
   size and SHA-256, and only then atomically replaces or installs the selected
   destination. Copy/verification/replacement failures clean staging and do not
   pre-delete an existing destination.
4. Meeting suggestions are persisted but off by default, suggestion-only, and
   driven by explicit native/browser allowlists. Browser title matching occurs
   only with Evee's existing Accessibility permission; page content is never
   read. Start Meeting is the sole suggestion path into `beginMeeting()`, while
   Dismiss records a per-application one-hour cooldown. Transform copy is backed
   by the deterministic pipeline's single supported-command summary, and open-
   ended rewrites still preserve the selection by throwing
   `unsupportedInstruction`.

No meeting recording is started automatically. Privacy mode is intentionally
ephemeral and does not alter persisted settings or delete content.

## TDD evidence

### Task 7 — privacy presentation

- RED: `swift run evee-core-checks --filter privacy-presentation` failed because
  `PrivacyPresentation` did not exist.
- GREEN: the same filter passed after adding the construction policy, session
  state, privacy-only view branches, menu escape hatch, and window installers.
- Mirrored XCTest: `PrivacyPresentationTests.swift` covers enabled and disabled
  construction behavior, accessible state, menu availability, and honest copy.

### Task 8 — search projection

- RED: the executable filter failed because `LibraryStore.searchResults` and
  indexed snippets did not exist. The mirrored XCTest runner was independently
  blocked before execution by this host's missing XCTest/Preview macro modules.
- GREEN: `search-projection` passed with synthetic canonical records and again
  after deliberately replacing an on-disk projection with non-SQLite bytes.
- Mirrored XCTest: `WorkspaceSearchTests` covers every indexed field with a
  unique literal, snippet provenance, injected `SQLITE_IOERR`, and the existing
  durable corruption recovery case.

### Task 9 — atomic audio export

- RED: `atomic-export` failed because `AtomicFileExporter` did not exist.
- GREEN: the filter passed for successful byte-identical replacement and an
  injected verification failure that preserved the old destination and cleaned
  the sibling staging file.
- Mirrored XCTest: `AtomicFileExporterTests.swift` covers success and injected
  copy, verification, and replacement failures.

### Task 10 — meeting suggestions and transform scope

- RED: `meeting-suggestion` failed because the settings, policy, snapshot, and
  supported-command summary did not exist.
- GREEN: the filter passed for off-by-default behavior, native allowlisting,
  missing browser title permission, title matching, active/expired cooldowns,
  and unsupported deterministic transform behavior.
- Mirrored XCTest: `MeetingSuggestionPolicyTests.swift` and
  `ContextTransformTests.swift` cover the policy branches and shared copy.

## Fresh verification

| Command or check | Result |
| --- | --- |
| All 39 explicit `evee-core-checks` filters, run serially | Passed. The 35 prior filters and all four new filters completed without a failure. |
| `swift run evee-core-checks --filter privacy-presentation` | Passed. |
| `swift run evee-core-checks --filter search-projection` | Passed, including actual corrupt-SQLite rebuild. |
| `swift run evee-core-checks --filter atomic-export` | Passed, including injected failure preservation. |
| `swift run evee-core-checks --filter meeting-suggestion` | Passed. |
| `swift build --target EveeCore --jobs 2` | Passed. |
| `swift build --target EveeApp --jobs 2` | Passed with the established temporary `canImport(PreviewsMacros)` guard around only KeyboardShortcuts 2.4.0's three preview declarations. The ignored dependency checkout was restored clean at mode `0444` and SHA-256 `12b7459a955f5566c3f8213ba0634e03e02affa76ae1195452d54261958d0c8e`. The build reports one pre-existing unreachable-default warning in `AppStore.swift`. |
| Direct `swiftc -typecheck` of every `Sources/EveeApp` Swift file against the built package and FluidAudio C modules | Passed. |
| `swiftc -parse` of every EveeApp and EveeCoreTests Swift source | Passed. |
| Focused source scans | Sensitive workspace/detail/settings roots occur only under the privacy-off roots; UI search rescanning and destination pre-deletion are absent; meeting runtime reads no selected/visible/page content; suggestion code has no automatic `beginMeeting()` call. |
| `git diff --check` | Passed. |

## Toolchain boundary

`xcode-select -p` is `/Library/Developer/CommandLineTools`, and no full Xcode
installation is available. A fresh `swift test --filter` invocation is blocked
before test execution because this SDK has no importable `XCTest` module and
cannot load KeyboardShortcuts' `PreviewsMacros`. Native XCTest execution is
therefore not claimed. The mirrored test files parse, the full app source
typechecks, both package targets compile under the available workarounds, and
the executable synthetic filters exercise the same core branches without real
configuration, recordings, or user data.

## Privacy and scope review

- `NSWindow.sharingType = .none` is described as best effort; privacy mode is
  presented as the reliable in-app hiding control.
- Privacy mode uses SwiftUI branching before `SettingsView`, navigation routes,
  record details, notes, context, credentials, and secret fields are built.
- Search remains a disposable local projection of canonical JSON and adds no
  secret or audio material beyond already-permitted record fields.
- Export staging is created beside the user-selected destination and removed on
  every exit path exercised by the checks.
- Suggestions observe only application identity while enabled. Browser window
  titles require existing Accessibility permission, and no browser page content
  or focused text is collected.
- Task 10 remains minimal parity polish: no calendar automation, meeting join
  automation, recording auto-start, or visual redesign was introduced.

## Fix round 1 — actionable meeting suggestions and exact transform copy

Review of `365b051` found that activating Evee to use the suggestion banner was
being treated as an unrelated foreground application. The runtime now classifies
Evee activation before external metadata extraction, using the current process
identifier first and a normalized bundle identifier as fallback. A dedicated
core transition preserves a pending suggestion for that event, while a genuine
external nonmatch, missing external identity, disabled settings, or Dismiss still
clears it. Recording remains reachable only through the existing explicit Start
Meeting action.

The deterministic transform summary and unsupported-instruction error now name
the exact replacement grammar and behavior:
`replace … with … (case-insensitive, all matches)`. The executable and mirrored
XCTest checks exercise two differently cased matches so the copy cannot drift
from the parser's actual semantics.

TDD evidence:

- RED: `meeting-suggestion` failed because `nextSuggestion` and its self-
  activation event did not exist. A second RED check failed because the
  process/bundle identity matcher did not exist.
- GREEN: the rebuilt executable's `meeting-suggestion` filter passed with self-
  activation preservation, external nonmatch clearing, Dismiss clearing,
  process-first/bundle-fallback identity, exact copy, and actual all-match case-
  insensitive replacement behavior.

Fresh fix verification:

- All 40 current executable core filters passed serially, including
  `meeting-suggestion` and the concurrently added `resource-seal` check.
- `swift build --target EveeCore --jobs 2` passed.
- Direct `swiftc -typecheck` of all current EveeApp sources passed against the
  built package and FluidAudio C modules.
- The focused diff, private-path, generated-artifact, secret-signature, full
  prohibited-tree, commit-metadata, and whitespace scans passed before commit.
