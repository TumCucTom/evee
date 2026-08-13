# Packaged Verification and Physical Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make packaged validation reproducible, isolated from real Evee data, semantically exercise all eleven helper tools from a relocated bundle, and produce trustworthy physical-Mac release evidence.

**Architecture:** Add small verification-only executables for synthetic fixture seeding and Launch Services probing, while keeping production self-test dispatch separate from normal SwiftUI startup. Centralize toolchain checks in a sourced shell library, verify resource seals in EveeCore, and make the package verifier own one temporary Foundation home from setup through cleanup.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI/AppKit, Foundation, CryptoKit, XCTest, Bash, Python 3, macOS codesign and Launch Services

**Spec:** `docs/superpowers/specs/2026-08-13-production-hardening-design.md`

## Global Constraints

- Minimum deployment target remains macOS 14.
- Full local build and packaging require Xcode 16 or newer, not standalone Command Line Tools.
- Generated verification data never uses the real Evee application-support directory.
- Self-test mode never constructs `AppStore`, normal scenes, shortcuts, capture, integrations, workspace intelligence, or shared stores.
- Every helper subprocess receives the same explicit temporary Foundation home.
- All eleven advertised helper tools must prove distinct domain semantics from deterministic synthetic fixtures.
- The relocated app bundle, not a SwiftPM executable in its build directory, is the packaging-test subject.
- Physical acceptance evidence remains outside the repository and contains no real transcript, credential, model, or private path content.
- Heavyweight tests, builds, packaging, and long recordings run serially after inspecting existing heavyweight processes and Docker workloads.
- Repository files, branches, commits, pull-request metadata, workflows, and artifact names use neutral product language only.
- Developer ID signing, notarisation, and publication remain separately reported owner-controlled gates.

## File Structure

- `scripts/lib/toolchain.sh`: reusable full-Xcode, version, command, and free-space preflight functions.
- `scripts/preflight.sh`: user-facing preflight entry point used by packaging and release scripts.
- `Sources/EveeCore/Packaging/ResourceSealVerifier.swift`: pure resource-seal parser and verifier.
- `Sources/EveeApp/EveeMain.swift`: process entry point that dispatches self-test before SwiftUI app construction.
- `Sources/EveeVerificationFixture/main.swift`: verification-only synthetic workspace and activity fixture writer.
- `Sources/EveeLaunchProbe/main.swift`: verification-only Launch Services launcher with an isolated environment and termination result.
- `scripts/verify_mcp_tools.py`: protocol driver and semantic assertions for the eleven tools.
- `scripts/verify_app.sh`: orchestration, relocation, isolation, signing, dependency, self-test, and helper verification.
- `scripts/smoke_mcp.sh`: fast isolated helper smoke that reuses the same fixture and semantic verifier.
- `Tests/Packaging/*.sh`: focused black-box tests for shell preflight, verifier isolation, and relocation.
- `Tests/EveeCoreTests/ResourceSealVerifierTests.swift`: resource-seal unit tests.
- `docs/PHYSICAL_VALIDATION.md`: private evidence protocol, commands, pass criteria, and restoration rules.

---

### Task 1: Full-Xcode and disk-space preflight

**Files:**
- Create: `scripts/lib/toolchain.sh`
- Create: `scripts/preflight.sh`
- Create: `Tests/Packaging/toolchain_preflight_test.sh`
- Modify: `scripts/package_app.sh:1-21`
- Modify: `scripts/release_app.sh:1-16`
- Modify: `README.md:34-57`

**Interfaces:**
- Produces: `require_full_xcode`, `require_command`, `require_free_space_gib`, and `scripts/preflight.sh [build|package|release]`.
- Consumers: `package_app.sh`, `release_app.sh`, Task 6 verification commands, and maintainers preparing a physical validation run.

- [ ] **Step 1: Write the failing shell test**

Create a temporary `PATH` containing controlled `xcode-select`, `xcrun`, `xcodebuild`, and `df` stubs. Exercise these cases separately:

```bash
run_expect_failure clt-only env PATH="$fixture_bin:$PATH" FAKE_DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/preflight.sh package
grep -q 'Select full Xcode 16 or newer with xcode-select' "$stderr_file"

run_expect_failure old-xcode env PATH="$fixture_bin:$PATH" FAKE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FAKE_XCODE_VERSION=15.4 scripts/preflight.sh package
grep -q 'Xcode 16 or newer is required' "$stderr_file"

run_expect_failure low-space env PATH="$fixture_bin:$PATH" FAKE_XCODE_VERSION=16.4 FAKE_AVAILABLE_KIB=1048576 scripts/preflight.sh package
grep -q 'at least 15 GiB free' "$stderr_file"

env PATH="$fixture_bin:$PATH" FAKE_XCODE_VERSION=16.4 FAKE_AVAILABLE_KIB=31457280 scripts/preflight.sh package
```

The stubs read only the named `FAKE_*` variables; the test must not change the machine's selected developer directory.

- [ ] **Step 2: Run the red test**

Run: `bash Tests/Packaging/toolchain_preflight_test.sh`

Expected: FAIL because `scripts/preflight.sh` does not exist.

- [ ] **Step 3: Implement the minimal preflight**

Implement source-safe functions with no global directory changes:

```bash
require_full_xcode() {
  local developer_dir version major
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$developer_dir" != */Contents/Developer ]] || [[ "$developer_dir" == /Library/Developer/CommandLineTools ]]; then
    echo "Select full Xcode 16 or newer with xcode-select before building Evee." >&2
    return 69
  fi
  version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
  major="${version%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 16 )); then
    echo "Xcode 16 or newer is required; selected version is ${version:-unknown}." >&2
    return 69
  fi
}

require_free_space_gib() {
  local path="$1" required_gib="$2" available_kib required_kib
  available_kib="$(df -Pk "$path" | awk 'NR == 2 { print $4 }')"
  required_kib=$((required_gib * 1024 * 1024))
  if (( available_kib < required_kib )); then
    echo "Packaging requires at least ${required_gib} GiB free for dependencies, models, recordings, and temporary bundle copies." >&2
    return 70
  fi
}
```

`scripts/preflight.sh` requires `swift`, `xcodebuild`, `xcrun`, `codesign`, `shasum`, `plutil`, `ditto`, `python3`, and `otool`; package/release modes require 15 GiB free at the repository root. Source it at the top of both packaging scripts before `swift build` or credential checks.

- [ ] **Step 4: Run green tests and real read-only preflight**

Run: `bash Tests/Packaging/toolchain_preflight_test.sh`

Expected: PASS for Command Line Tools, old Xcode, low disk, and supported Xcode fixtures.

Run: `scripts/preflight.sh package`

Expected: either PASS with selected Xcode and free-space summaries, or exit 69/70 with the exact actionable local blocker. It must not begin a build.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/toolchain.sh scripts/preflight.sh Tests/Packaging/toolchain_preflight_test.sh scripts/package_app.sh scripts/release_app.sh README.md
git commit -m "Add packaging toolchain preflight"
```

### Task 2: Isolated self-test entry point and complete resource-seal verification

**Files:**
- Create: `Sources/EveeCore/Packaging/ResourceSealVerifier.swift`
- Create: `Sources/EveeApp/EveeMain.swift`
- Modify: `Sources/EveeApp/EveeApp.swift:7-46`
- Modify: `Sources/EveeApp/InstallationSelfTest.swift`
- Create: `Tests/EveeCoreTests/ResourceSealVerifierTests.swift`
- Create: `Tests/Packaging/self_test_entrypoint_test.sh`

**Interfaces:**
- Produces: `ResourceSealVerifier.verify(resourcesURL:sealName:)`, `InstallationSelfTest.run(rootURL:)`, optional isolated self-test result-file reporting, and an entry point that invokes `EveeApplication.main()` only in normal mode.
- Consumers: packaged self-test in Task 6 and normal app startup.

- [ ] **Step 1: Write failing seal tests**

Use a temporary resources directory and cover a valid seal, changed bytes, a missing file, an unsealed extra file, duplicate entries, `../` traversal, absolute paths, malformed digest text, and symbolic links:

```swift
func testValidSealPassesAndTamperingFails() throws {
    let root = try makeResources(["Model.bundle/config.json": Data("safe".utf8)])
    try writeSeal(for: root)
    XCTAssertNoThrow(try ResourceSealVerifier.verify(resourcesURL: root))

    try Data("changed".utf8).write(to: root.appendingPathComponent("Model.bundle/config.json"))
    XCTAssertThrowsError(try ResourceSealVerifier.verify(resourcesURL: root))
}

func testSealRejectsTraversalAndUnsealedFiles() throws {
    let root = try makeResources(["expected.txt": Data("safe".utf8)])
    try Data(String(repeating: "0", count: 64).appending("  ../outside\n").utf8)
        .write(to: root.appendingPathComponent(".evee-resource-seal.sha256"))
    XCTAssertThrowsError(try ResourceSealVerifier.verify(resourcesURL: root))
}
```

The shell test statically asserts that `@main` exists only in `EveeMain.swift`, starts the packaged executable with `--installation-self-test`, and fails if the process creates `Library/Application Support/Evee` inside its temporary Foundation home.

- [ ] **Step 2: Run the red tests**

Run: `swift test --filter ResourceSealVerifierTests`

Expected: FAIL because `ResourceSealVerifier` is missing.

Run: `bash Tests/Packaging/self_test_entrypoint_test.sh`

Expected: FAIL because self-test still constructs normal SwiftUI app state.

- [ ] **Step 3: Implement the resource verifier and process dispatch**

The verifier parses exactly 64 lowercase hexadecimal characters, two spaces, and a relative path per line. It resolves each path under `resourcesURL`, rejects symlinks and duplicate paths, hashes with `SHA256`, and compares the sealed set with every regular file other than the seal itself.

```swift
public enum ResourceSealError: Error {
    case missingSeal, fileSetMismatch
    case malformedEntry(String), unsafePath(String), duplicatePath(String)
    case missingResource(String), digestMismatch(String)
}

public enum ResourceSealVerifier {
    public static func verify(
        resourcesURL: URL,
        sealName: String = ".evee-resource-seal.sha256"
    ) throws {
        let sealURL = resourcesURL.appendingPathComponent(sealName)
        guard let text = try? String(contentsOf: sealURL, encoding: .utf8) else {
            throw ResourceSealError.missingSeal
        }
        let root = resourcesURL.standardizedFileURL.path + "/"
        var sealed = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            guard line.count > 66 else { throw ResourceSealError.malformedEntry(String(line)) }
            let digest = String(line.prefix(64))
            let separator = line.dropFirst(64).prefix(2)
            let relative = String(line.dropFirst(66))
                .replacingOccurrences(of: "./", with: "", options: [.anchored])
            guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  separator == "  ", !relative.isEmpty else {
                throw ResourceSealError.malformedEntry(String(line))
            }
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw ResourceSealError.unsafePath(relative)
            }
            guard sealed.insert(relative).inserted else { throw ResourceSealError.duplicatePath(relative) }
            let file = resourcesURL.appendingPathComponent(relative).standardizedFileURL
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard file.path.hasPrefix(root), values?.isRegularFile == true,
                  values?.isSymbolicLink != true else {
                throw ResourceSealError.missingResource(relative)
            }
            let actual = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { throw ResourceSealError.digestMismatch(relative) }
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: resourcesURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        let actual = Set((enumerator?.allObjects as? [URL] ?? []).compactMap { file -> String? in
            guard file.standardizedFileURL != sealURL.standardizedFileURL,
                  (try? file.resourceValues(forKeys: keys).isRegularFile) == true else { return nil }
            return String(file.standardizedFileURL.path.dropFirst(root.count))
        })
        guard actual == sealed else { throw ResourceSealError.fileSetMismatch }
    }
}
```

Move process selection before the SwiftUI `App` type:

```swift
@main
enum EveeMain {
    static func main() {
        guard CommandLine.arguments.contains("--installation-self-test") else {
            EveeApplication.main()
            return
        }
        Task {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("evee-self-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try await InstallationSelfTest.run(rootURL: root)
                print("Evee installation self-test passed")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fputs("Evee installation self-test failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

struct EveeApplication: App {
    @StateObject private var store = AppStore()
}
```

Move the current `body`, menu icon, and scene construction from `EveeApp` to `EveeApplication` without changing scene behavior. `InstallationSelfTest.run(rootURL:)` must instantiate only `LibraryStore(rootURL:)`, verify the actual bundle seal, inspect the bundled helper, round-trip one synthetic record in `rootURL`, and prove legacy secrets do not encode. It must not reference `.shared` stores or `AppStore`.

When `EVEE_SELF_TEST_RESULT_PATH` is present, require an absolute path whose parent already exists. Write `{"status":"passed"}` atomically before successful exit and `{"status":"failed","category":"installation-self-test"}` before failed exit. Never include error descriptions, paths, records, or credentials in this machine-readable result.

- [ ] **Step 4: Run focused tests and source-boundary checks**

Run: `swift test --filter ResourceSealVerifierTests`

Expected: PASS for valid, corrupt, missing, extra, traversal, duplicate, malformed, and symlink cases.

Run: `rg -n '@main|AppStore\(|\.shared|bootstrap\(' Sources/EveeApp/EveeMain.swift Sources/EveeApp/InstallationSelfTest.swift`

Expected: `@main` only in `EveeMain.swift`; `AppStore()` only inside `EveeApplication`; no `.shared` or `bootstrap` in `InstallationSelfTest.swift`.

Run: `bash Tests/Packaging/self_test_entrypoint_test.sh`

Expected: PASS and no normal application-support directory created.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Packaging/ResourceSealVerifier.swift Sources/EveeApp/EveeMain.swift Sources/EveeApp/EveeApp.swift Sources/EveeApp/InstallationSelfTest.swift Tests/EveeCoreTests/ResourceSealVerifierTests.swift Tests/Packaging/self_test_entrypoint_test.sh
git commit -m "Isolate packaged installation self-test"
```

### Task 3: Deterministic synthetic domain fixture seeder

**Files:**
- Modify: `Package.swift`
- Create: `Sources/EveeVerificationFixture/main.swift`
- Create: `Tests/Packaging/fixture_seeder_test.sh`

**Interfaces:**
- Consumes: `LibraryStore(rootURL:)`, `WorkspaceIntelligenceStore(rootURL:)`, `EveeSettings.mcpEnabled`, and public record/intelligence models delivered by the privacy integration workstream.
- Produces: executable `evee-verification-fixture --home <absolute-path>` and deterministic fixture IDs/content used by Tasks 4 and 6.

- [ ] **Step 1: Write the failing fixture black-box test**

```bash
fixture_home="$(mktemp -d /tmp/evee-fixture-test.XXXXXX)"
trap 'rm -rf "$fixture_home"' EXIT
swift run evee-verification-fixture --home "$fixture_home"
test -f "$fixture_home/Library/Application Support/Evee/records.json"
test -f "$fixture_home/Library/Application Support/Evee/settings.json"
test -f "$fixture_home/Library/Application Support/Evee/Intelligence/dwell-events.json"
test "$(find "$fixture_home" -type f -perm -004 -print | wc -l | tr -d ' ')" = 0
```

Decode `records.json` in Python and require exactly one dictation, one meeting, and one memo with the fixed UUIDs below. Require the settings fixture to enable helper access without storing any token or webhook secret.

- [ ] **Step 2: Run the red fixture test**

Run: `bash Tests/Packaging/fixture_seeder_test.sh`

Expected: FAIL because `evee-verification-fixture` is not a product.

- [ ] **Step 3: Add the verification-only executable and seed exact semantics**

Add an executable product and target depending only on EveeCore. Parse `--home`, require an absolute directory outside the real Application Support path, and refuse to continue if its `Library/Application Support/Evee` target already exists. Construct roots explicitly:

```swift
let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
let workspaceRoot = support.appendingPathComponent("Evee", isDirectory: true)
let store = LibraryStore(rootURL: workspaceRoot)
let intelligence = WorkspaceIntelligenceStore(
    rootURL: workspaceRoot.appendingPathComponent("Intelligence", isDirectory: true)
)
```

Seed these stable records:

```swift
let dictationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
let meetingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
let memoID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

let dictation = WorkspaceRecord(
    id: dictationID,
    kind: .dictation,
    createdAt: now.addingTimeInterval(-180),
    updatedAt: now.addingTimeInterval(-180),
    title: "Synthetic dictation",
    text: "Alpha verification phrase for search",
    sourceApplication: "Fixture Editor",
    duration: 4
)
```

The meeting contains two chronological segments with honest channel attribution, notes `Decision evidence: ship the isolated verifier`, one extractive decision, and one extractive action. The memo contains `Remember to inspect the packaged helper`, a highlight, and the action `Inspect the packaged helper`. Set all audio paths, recovery identifiers, webhook deliveries, URLs, recipients, and secrets to absent values.

Seed activity with Editor followed by Browser, current Browser context, application usage, and a daily journal entry by recording two observations and stopping with `minimumDwellSeconds: 1`. Save settings with `mcpEnabled = true`, model `.parakeet`, language `en`, three dictionary entries, two application styles, and local API/webhook disabled.

- [ ] **Step 4: Run the fixture test twice**

Run: `bash Tests/Packaging/fixture_seeder_test.sh`

Expected: PASS with three records, private permissions, enabled helper access, and domain-specific intelligence.

Run: `bash Tests/Packaging/fixture_seeder_test.sh`

Expected: PASS again with a fresh root and identical semantic values; timestamps may differ but IDs and content must not.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/EveeVerificationFixture/main.swift Tests/Packaging/fixture_seeder_test.sh
git commit -m "Add isolated verification fixtures"
```

### Task 4: Semantic protocol verification for all eleven helper tools

**Files:**
- Create: `scripts/verify_mcp_tools.py`
- Modify: `scripts/smoke_mcp.sh`
- Create: `Tests/Packaging/mcp_semantics_test.sh`

**Interfaces:**
- Consumes: `evee-verification-fixture --home`, a helper executable path, `CFFIXED_USER_HOME`, and the public helper schemas from the privacy integration workstream.
- Produces: `verify_mcp_tools.py --helper <path> --home <path>` with non-zero exit on protocol, tool-set, privacy, or semantic failure.

- [ ] **Step 1: Write the failing semantic harness test**

The shell test builds the helper and fixture seeder, creates a temporary home, seeds it, and invokes the Python verifier. Add a deliberately incorrect fake helper and require the verifier to reject it even though it returns syntactically valid JSON for all calls.

```bash
python3 scripts/verify_mcp_tools.py --helper "$helper" --home "$fixture_home"
if python3 scripts/verify_mcp_tools.py --helper "$fake_helper" --home "$fixture_home"; then
  echo "semantic verifier accepted constant tool output" >&2
  exit 1
fi
```

- [ ] **Step 2: Run the red semantic test**

Run: `bash Tests/Packaging/mcp_semantics_test.sh`

Expected: FAIL because `verify_mcp_tools.py` is missing.

- [ ] **Step 3: Implement protocol and domain assertions**

Start the helper with a minimal environment that preserves system execution while overriding both home variables:

```python
environment = os.environ.copy()
environment["HOME"] = str(home)
environment["CFFIXED_USER_HOME"] = str(home)
process = subprocess.Popen(
    [str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, env=environment,
)
```

Send `initialize`, `tools/list`, and one `tools/call` request for each exact tool name. Decode each text content value as JSON and assert:

- `search`: one hit for `Alpha verification phrase`, with a matching snippet and the fixed dictation UUID.
- `recent_activity`: exactly three typed records ordered newest first; a `kind: meeting` request returns only the fixed meeting.
- `ambient_timeline`: enabled, contains the Editor dwell event, and contains no transcript text.
- `ambient_app_usage`: Browser and Editor usage are genuine duration/count aggregates.
- `get_context`: enabled current Browser context from the activity store, not a renamed voice record.
- `get_journal`: enabled journal entry has activity duration plus `voiceRecordCount == 3`, one dictation, one meeting, one memo, and the seeded decision/action evidence.
- `get_dictation`: fixed dictation UUID and dictation text.
- `get_meeting`: fixed meeting UUID, two timed segments, notes, decision, and action.
- `get_memo`: fixed memo UUID, highlight, and memo action.
- `get_stats`: total records 3, each kind count 1, positive duration, and non-zero word count.
- `get_config`: helper enabled, model Parakeet, language `en`, dictionary count 3, application style count 2, and local API/webhook disabled.

Recursively reject keys `audioRelativePath`, `audioTracks`, `relativePath`, `recoverySourceID`, `webhookDeliveries`, `payloadBody`, `rawText`, `token`, and `webhookSecret`. Reject the real home path, repository path, fixture root path, and strings matching `api.token` anywhere in output.

Also send invalid `kind`, invalid `since`, invalid UUID, zero limit, and limit 201 requests. Require JSON-RPC invalid-parameter errors and no content result.

- [ ] **Step 4: Run semantic and smoke checks**

Run: `bash Tests/Packaging/mcp_semantics_test.sh`

Expected: PASS for the real helper and expected rejection of the constant-output fake.

Run: `bash scripts/smoke_mcp.sh`

Expected: PASS after creating and removing its own fixture home. `git status --short` remains unchanged.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify_mcp_tools.py scripts/smoke_mcp.sh Tests/Packaging/mcp_semantics_test.sh
git commit -m "Verify helper domain semantics"
```

### Task 5: Launch Services relocation probe

**Files:**
- Modify: `Package.swift`
- Create: `Sources/EveeLaunchProbe/main.swift`
- Create: `Tests/Packaging/launch_probe_test.sh`

**Interfaces:**
- Consumes: `EVEE_SELF_TEST_RESULT_PATH` reporting from Task 2.
- Produces: `evee-launch-probe --app <bundle> --home <directory> --argument <value> --wait`.
- Consumers: relocated installation self-test in Task 6 and the physical lifecycle protocol in Task 7.

- [ ] **Step 1: Write the failing Launch Services probe test**

Build and package once, copy the bundle to a path containing spaces outside `dist`, and launch self-test through the missing probe:

```bash
relocated_root="$(mktemp -d /tmp/evee-relocation-test.XXXXXX)"
trap 'rm -rf "$relocated_root"' EXIT
ditto dist/Evee.app "$relocated_root/Installed Candidate/Evee.app"
swift run evee-launch-probe \
  --app "$relocated_root/Installed Candidate/Evee.app" \
  --home "$relocated_root/Foundation Home" \
  --argument=--installation-self-test \
  --wait
test ! -e "$relocated_root/Foundation Home/Library/Application Support/Evee"
```

- [ ] **Step 2: Run the red relocation test**

Run: `bash Tests/Packaging/launch_probe_test.sh`

Expected: FAIL because `evee-launch-probe` is absent.

- [ ] **Step 3: Implement the AppKit launch probe**

Use `NSWorkspace.OpenConfiguration`, not `Process`, so the relocated bundle is resolved through Launch Services:

```swift
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.createsNewApplicationInstance = true
configuration.arguments = arguments
var environment = ProcessInfo.processInfo.environment
environment["HOME"] = home.path
environment["CFFIXED_USER_HOME"] = home.path
let resultURL = home.appendingPathComponent("installation-self-test-result.json")
environment["EVEE_SELF_TEST_RESULT_PATH"] = resultURL.path
configuration.environment = environment

let application = try await NSWorkspace.shared.openApplication(
    at: appURL,
    configuration: configuration
)
```

For `--wait`, observe `NSWorkspace.didTerminateApplicationNotification` for that process identifier and enforce a 30-second timeout. Because `NSRunningApplication` does not expose a child exit status, require the result file to decode as exactly `{"status":"passed"}` after termination; missing, failed, malformed, or oversized result data is failure. Reject non-absolute paths, bundle paths inside `.build` or `dist`, and a home equal to the real user home or containing the real Evee Application Support directory.

- [ ] **Step 4: Run relocation and negative-path checks**

Run: `bash Tests/Packaging/launch_probe_test.sh`

Expected: PASS through Launch Services from a space-containing relocated path, self-test exits successfully, and no normal data root appears.

Run: `swift run evee-launch-probe --app dist/Evee.app --home "$HOME" --argument=--installation-self-test --wait`

Expected: non-zero exit with `Refusing to use the real user home for validation.`

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/EveeLaunchProbe/main.swift Tests/Packaging/launch_probe_test.sh
git commit -m "Probe relocated app lifecycle"
```

### Task 6: End-to-end isolated package verifier

**Files:**
- Modify: `scripts/verify_app.sh`
- Modify: `scripts/package_app.sh`
- Create: `Tests/Packaging/verifier_isolation_test.sh`
- Modify: `.github/workflows/macos.yml:18-35`
- Modify: `.github/workflows/release.yml:21-67`

**Interfaces:**
- Consumes: preflight, resource verification, fixture seeder, semantic MCP verifier, and Launch Services probe.
- Produces: `scripts/verify_app.sh <app-path>` that verifies only a relocated copy against one owned temporary home and emits no private fixture content.

- [ ] **Step 1: Write the failing isolation sentinel test**

Create a fake real home with a sentinel record, place an `fs_usage`-independent read trap by making that real record unreadable, and run the verifier with the environment pointing to the fake real home:

```bash
real_home="$(mktemp -d /tmp/evee-real-sentinel.XXXXXX)"
mkdir -p "$real_home/Library/Application Support/Evee"
printf '%s\n' 'REAL-DATA-SENTINEL-DO-NOT-READ' >"$real_home/Library/Application Support/Evee/records.json"
chmod 000 "$real_home/Library/Application Support/Evee/records.json"
HOME="$real_home" CFFIXED_USER_HOME="$real_home" scripts/verify_app.sh dist/Evee.app >"$output" 2>"$errors"
chmod 600 "$real_home/Library/Application Support/Evee/records.json"
grep -q 'Verified isolated relocated bundle' "$output"
! grep -R -q 'REAL-DATA-SENTINEL-DO-NOT-READ' "$output" "$errors" /tmp/evee-verifier.* 2>/dev/null
```

Hash the sentinel before and after. Run the verifier once more against a deliberately malformed bundle, require a non-zero result, and assert that both successful and failed runs remove every owned `/tmp/evee-verifier.*` directory.

- [ ] **Step 2: Run the red verifier test**

Run: `bash Tests/Packaging/verifier_isolation_test.sh`

Expected: FAIL because the current verifier invokes the helper against the caller's default Application Support data.

- [ ] **Step 3: Refactor the verifier around one owned temporary root**

Create exactly one root and install cleanup before any other temporary resource:

```bash
verification_root="$(mktemp -d /tmp/evee-verifier.XXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT
  chmod -R u+rwX "$verification_root" 2>/dev/null || true
  rm -rf "$verification_root"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

foundation_home="$verification_root/FoundationHome"
relocated_app="$verification_root/Installed/Evee.app"
mkdir -p "$foundation_home" "$(dirname "$relocated_app")"
ditto "$app_dir" "$relocated_app"
```

Perform these checks in order:

1. Reject symbolic links, verify Info.plist identity/version/minimum system, and verify every resource digest.
2. Verify the outer bundle and nested helper signatures separately with `codesign --strict`; do not use `--deep` as a substitute for nested-code checks.
3. Inspect app entitlements and require audio input; for Developer ID candidates require hardened runtime and trusted authority.
4. Inspect `otool -L` for unresolved absolute build-tree dependencies in both executables.
5. Run the relocated executable directly with `HOME` and `CFFIXED_USER_HOME` set to the temporary home and `--installation-self-test`.
6. Run the same self-test through `evee-launch-probe` to exercise Launch Services relocation.
7. Seed the temporary home using `evee-verification-fixture --home`.
8. Invoke the helper only from `relocated_app/Contents/Helpers/evee-mcp` through `verify_mcp_tools.py`.
9. Search all captured stdout/stderr for the real home, repository root, build directory, sentinel marker, tokens, and fixture-private paths.

The verifier must never open the caller's real records/settings to calculate comparison hashes. The black-box isolation test owns before/after hashes outside the verifier process.

Do not print tool response bodies on success. On failure, print only request ID, tool name, assertion name, and redacted error category.

- [ ] **Step 4: Run focused package verification serially**

Run: `bash Tests/Packaging/verifier_isolation_test.sh`

Expected: PASS with an unreadable real sentinel, unchanged hashes, semantic tool checks, and cleanup after both successful and deliberately failed verification.

Run: `scripts/preflight.sh package && scripts/package_app.sh release && scripts/verify_app.sh dist/Evee.app`

Expected: package succeeds and verifier prints `Verified isolated relocated bundle` for the exact app path.

Update CI to run `scripts/preflight.sh package`, packaging, isolation test, and verifier serially. Keep the existing pinned Xcode selection and artifact upload behavior.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify_app.sh scripts/package_app.sh Tests/Packaging/verifier_isolation_test.sh .github/workflows/macos.yml .github/workflows/release.yml
git commit -m "Isolate relocated package verification"
```

### Task 7: Private physical-Mac evidence protocol

**Files:**
- Create: `docs/PHYSICAL_VALIDATION.md`
- Modify: `docs/PRODUCT_RELEASE_GATES.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the exact committed bundle produced and verified by Task 6.
- Produces: a documented protocol whose evidence root is supplied by the operator and must resolve outside the repository and real Evee Application Support directory.

- [ ] **Step 1: Write the protocol acceptance checklist before prose**

The document must require this evidence header:

```text
Candidate commit:
Main executable SHA-256:
Resource seal SHA-256:
CFBundleIdentifier:
CFBundleShortVersionString:
CFBundleVersion:
Code-signing authority/ad-hoc status:
Relocated bundle path:
Isolated data root or disposable macOS account:
Start time:
First significant issue time or "none after <duration>":
Existing heavyweight processes/containers inspected:
```

For every journey row require: setup, exact input action, expected output, observed UI result, VoiceOver/keyboard result, disk effect, privacy effect, cancellation/recovery result, pass/fail/externally blocked, issue identifier, and timestamped evidence filename.

- [ ] **Step 2: Add exact safe setup and restoration commands**

Document commands that create a private evidence root outside the repository, copy the verified app, capture bundle metadata, and refuse unsafe locations:

```bash
evidence_root="$(mktemp -d /tmp/evee-physical-evidence.XXXXXX)"
chmod 700 "$evidence_root"
ditto dist/Evee.app "$evidence_root/Installed/Evee.app"
git rev-parse HEAD >"$evidence_root/commit.txt"
shasum -a 256 "$evidence_root/Installed/Evee.app/Contents/MacOS/Evee" >"$evidence_root/bundle-executable.sha256"
shasum -a 256 "$evidence_root/Installed/Evee.app/Contents/Resources/.evee-resource-seal.sha256" >"$evidence_root/resource-seal.sha256"
codesign -dvvv "$evidence_root/Installed/Evee.app" 2>"$evidence_root/signature.txt"
mkdir -p "$evidence_root/FoundationHome"
swift run evee-launch-probe --app "$evidence_root/Installed/Evee.app" --home "$evidence_root/FoundationHome"
```

State that permission reset or destructive recovery testing requires either a disposable macOS user or an explicit backup of `~/Library/Application Support/Evee`, Keychain items, and current TCC state with a written restoration plan. Never instruct an operator to reset permissions or delete real data by default.

- [ ] **Step 3: Define all ten journey groups and evidence thresholds**

Repeat all mandatory journey groups from the approved design and require the packaged relocated app for each: onboarding; external-app dictation; hands-free/wake phrase; selection transformation; meeting; memo; workspace; settings/accessibility; integrations; installed-product lifecycle.

For integrations, record fragmented API request behavior, token rotation, disabled-connection EOF, webhook redirect refusal, delayed-send cancellation, relaunch retry, helper registration/revocation, and semantic output for all eleven tools. For meeting and memo, record retained-file hashes before/after recovery and export. For accessibility, include light/dark, Reduce Motion, keyboard-only, VoiceOver announcements, and small-window screenshots with sensitive content replaced by synthetic text.

Define a significant issue as data loss, privacy leakage, blocked primary journey, incorrect output, unreadable UI, or failure without actionable recovery. Require two uninterrupted hours of normal use with no significant issue before candidate approval.

- [ ] **Step 4: Review protocol against privacy and release invariants**

Run: `rg -n 'commit|Bundle|isolated|VoiceOver|privacy|recovery|first significant|two hours|onboarding|dictation|wake|selection|meeting|memo|workspace|accessibility|integrations|lifecycle' docs/PHYSICAL_VALIDATION.md`

Expected: every evidence field and all ten journey groups have an explicit match.

Run: `rg -n 'rm -rf.*Application Support/Evee|tccutil reset|security delete' docs/PHYSICAL_VALIDATION.md`

Expected: no destructive default command. Any mention appears only as an owner-approved/disposable-account warning, without an executable command.

- [ ] **Step 5: Commit**

```bash
git add docs/PHYSICAL_VALIDATION.md docs/PRODUCT_RELEASE_GATES.md README.md
git commit -m "Document physical acceptance evidence"
```

### Task 8: Exact-head serialized validation and release-evidence handoff

**Files:**
- Modify: `docs/superpowers/plans/2026-08-13-packaged-verification.md`
- Modify: `docs/PRODUCT_RELEASE_GATES.md`

**Interfaces:**
- Consumes: Tasks 1–7 and the exact candidate commit.
- Produces: checked plan evidence for automated/package gates and an honest list of physical passes, remaining software failures, and external release blockers.

- [ ] **Step 1: Inspect resource pressure before heavyweight validation**

Run: `ps -axo pid,rss,command | sort -nr -k2 | head -20`

Run: `docker ps --format '{{.ID}} {{.Names}} {{.Status}}' 2>/dev/null || true`

Expected: record pre-existing heavyweight workloads in private evidence. Do not stop workloads not started for this task. Run all following heavyweight commands serially.

- [ ] **Step 2: Run focused and full automated validation**

Run: `bash Tests/Packaging/toolchain_preflight_test.sh && bash Tests/Packaging/fixture_seeder_test.sh && bash Tests/Packaging/mcp_semantics_test.sh`

Expected: all focused packaging tests PASS.

Run: `swift test --filter ResourceSealVerifierTests`

Expected: focused XCTest PASS.

Run: `swift test`

Expected: complete suite PASS with no unexpected crash, hang, or skipped critical test.

- [ ] **Step 3: Package and verify the exact head**

Run: `candidate_commit="$(git rev-parse HEAD)"; scripts/preflight.sh package && scripts/package_app.sh release && scripts/verify_app.sh dist/Evee.app; test "$candidate_commit" = "$(git rev-parse HEAD)"`

Expected: exact head unchanged; ad-hoc local package verifies from the relocated copy using isolated synthetic data and all eleven semantic tool assertions.

Run: `git status --short`

Expected: no generated fixture data, models, evidence, temporary homes, app data, or package logs are staged.

- [ ] **Step 4: Execute physical protocol and record honest status**

Follow `docs/PHYSICAL_VALIDATION.md` against the exact relocated bundle. Record pass, fail, or external blocker for every journey and elapsed time to first significant issue. A failed journey creates or updates its distinct Linear child issue before software changes; repeat affected automated and physical checks after each fix.

Expected: no P0/P1 software issue remains and the final normal-use session reaches two hours without a significant issue. Missing signing/notarisation credentials remain external blockers and do not convert an unsigned local pass into a public-release pass.

- [ ] **Step 5: Perform final repository and metadata scans, then commit evidence wording only**

Run: `git diff --check`

Run: `git ls-files | rg -n '(Application Support/Evee|\.caf$|\.m4a$|\.wav$|\.p8$|\.p12$|Evee\.app|physical-evidence)'`

Expected: no generated app data, audio, credentials, app bundle, or private evidence file is tracked.

Run the complete prohibited-reference scan required by the project instructions across the proposed tree and every new commit subject/body. Expected: zero matches.

```bash
git add docs/superpowers/plans/2026-08-13-packaged-verification.md docs/PRODUCT_RELEASE_GATES.md
git commit -m "Record packaged verification evidence"
```

Do not mark physical steps complete in the committed plan unless the private matrix identifies the exact commit, bundle identity, and observed result. Do not commit the matrix, screenshots, permission state, machine paths, model files, or local transcripts.
