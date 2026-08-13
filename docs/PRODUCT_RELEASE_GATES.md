# Product completeness and release gates

Product completeness is not established by compiling or by the presence of a
type. A feature is complete only when its primary journey, failure states,
recovery, packaging, accessibility and automated acceptance tests all pass in
the distributed app.

## Release gates

Every release candidate must satisfy all of these gates on a clean Mac user
account in both light and dark appearances.

- First-run setup obtains Microphone and Accessibility permissions before
  dictation is enabled. Screen Recording is requested only when system audio is
  enabled.
- Pressing and releasing push-to-talk exactly once cannot start late, double
  start, double stop or remain recording after release.
- A dictation is durably saved before delivery. Paste failure never loses the
  transcript or recovery audio.
- Delivery targets the application in which dictation began, preserves every
  pasteboard representation, and reports a recoverable error if the target is
  no longer available.
- Recording, processing, success and error states are visible outside Evee's
  main window and announced to VoiceOver.
- Meeting retention preserves every enabled channel. Recovery survives a crash
  and can be resumed or explicitly discarded.
- The shipped app launches after being moved out of the build directory and
  contains every resource and helper executable it advertises.
- MCP setup from the distributed app succeeds and every advertised tool has a
  protocol and integration test.
- No secrets are stored in ordinary settings JSON. Sensitive local files have
  owner-only permissions and documented retention controls.
- The app passes keyboard-only, VoiceOver, Reduce Motion and dark-mode smoke
  tests.

## Product completeness checklist

### Dictation and transformation

- [x] System-wide press-and-hold dictation
- [x] Locked/hands-free recording and cancellation
- [x] System-wide status UI and configurable audio cues
- [x] Automatic paste, copy-only and auto-send delivery modes
- [x] Selected-text voice transformation
- [x] App, window, URL, document, recipient and selection context
- [x] Per-application styles with a user-facing editor
- [x] Email greeting/sign-off mode
- [x] Personal dictionary and spoken formatting
- [x] Smart links and learned personalisation

### Meetings and memos

- [x] Microphone and system-audio capture with input selection
- [x] Manual meeting start with explicit active-channel status
- [x] Live transcript preview and timed final utterances
- [x] Optional genuine anonymous speaker attribution with editable labels
- [x] Live notes with crash-safe autosave
- [x] Audio-health warnings, echo handling and recovery
- [x] Playback, export, search and topic navigation
- [x] Local summary, decisions and action items
- [x] Voice memos with title, summary, playback and retention controls
- [x] Screen-sharing privacy behaviour
- [x] Reliable webhooks with delivery status and retry

### Workspace and integrations

- [x] Indexed search across dictations, meetings and memos
- [x] Journal, recent activity, contextual timeline and statistics
- [x] History retention, deletion and export controls
- [x] Eleven documented MCP tools with setup/status UI
- [x] Usable authenticated loopback API with token rotation
- [ ] Launch-at-login, diagnostics, signed distribution and updates

### Local-integration privacy hardening

Command Line Tools checks cover the following code-level guarantees: optional
context is collected only when enabled; disabling the loopback API closes
active clients; webhook cancellation is terminal for outstanding delivery; and
managed MCP registrations are revocable, with disabled helper access rejected.
These checks do not satisfy the packaged-app, clean-client, accessibility or
physical-device release gates above.

## Required smoke journeys

The release checklist records time to first significant issue. A significant
issue is data loss, privacy leakage, a blocked primary journey, an incorrect
result, an unreadable screen or a failure without an actionable recovery path.

1. Clean install, permissions and first dictation into TextEdit.
2. Dictation while switching focus to another application.
3. Dictation with an image and rich text on the clipboard.
4. Rapid press/release and repeated shortcut input.
5. Memo start, stop, playback, edit and delete.
6. Thirty-minute meeting with both channels and two speakers.
7. Meeting interruption, app restart and recovery.
8. Search, edit and switch quickly between several records.
9. MCP installation and all tools from a clean client configuration.
10. Dark mode, keyboard-only and VoiceOver operation.

Product completeness can be claimed only when all ten journeys pass in the
packaged build and the time-to-first-significant-issue test runs for at least
two hours without a release-blocking failure.
