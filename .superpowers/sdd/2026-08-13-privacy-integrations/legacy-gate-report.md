# TOM-47 legacy registration gate

## Outcome

Local helper authorization now remains disabled when an unselected detected client has a recognized legacy or ambiguous Evee registration. The gate applies to both new-client enablement and legacy adoption, reports the remaining configuration paths, and performs no config or settings write when blocked.

The Settings UI permits explicit multi-selection of recognized legacy registrations and provides a batch adoption action. It continues to expose per-entry Adopt and Remove actions. Ambiguous/manual entries remain immutable and are called out as requiring review outside Evee.

## Regression coverage

`mcp-legacy` now verifies with temporary synthetic client configurations that:

- enabling a new client is blocked with legacy/ambiguous registrations unresolved;
- adopting only one recognized registration saves no authorization and changes no data;
- explicitly adopting both recognized registrations enables the helper while preserving configuration contents;
- removing one registration, then adopting the remaining recognized one, enables the helper.

## Verification

- `swift build --target EveeCore` — passed.
- `swift build --target EveeMCP` — passed.
- `evee-core-checks` filters — all 17 passed, including `mcp-legacy` and `mcp-revocation`.
- The isolated `mcp-revocation` smoke passed.
- `swift build --target EveeApp` remains blocked before compiling EveeApp by the existing `KeyboardShortcuts` Preview macro error: `PreviewsMacros.SwiftUIView` is unavailable in the Command Line Tools toolchain.

## Scope review

Only MCP ownership/adoption core logic, the existing MCP Settings UI, this focused core check, and this report changed. No package, CI, signing, entitlement, or other restricted metadata changed.
