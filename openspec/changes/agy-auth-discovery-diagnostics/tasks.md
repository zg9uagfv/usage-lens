# Tasks: agy-auth-discovery-diagnostics

Research amendment 2026-11-22. Earlier checks meant implementation was reported, not accepted; current review is REJECT. Only task 1 is complete in this dispatch. Execute serially in the shared workspace; researcher edits specifications only.

## 1. Research and bound the solution — **复杂任务** / researcher

- [x] Inspect implementation/spec/fixture/review/relay, installed AGY version/help, and primary Google documentation.
- **Acceptance:** design.md links evidence, separates prior claims from fresh observations, defines project/auth/environment boundaries, safe manual protocol and limitations. No real credential inspection or new inferred Keychain tuple.

## 2. Approve scope and handoff — **常规任务** / tech_lead

- [x] Confirm predecessor/subprocess exit, preserve dirty work and original local-Coder failure evidence, update relay atomically, approve Gemini request-flow/environment scope and resolve thermos availability.
- **Acceptance:** coordinator-owned revision/decision evidence in `.orca-relay/decisions.tsv` and `.orca-relay/state.json` confirms predecessor exits and frozen implementation (`6d2f1425...`), preserves the original external Orca `coder_local` start failure summary (`task_d97b1ccfb247`, `startFailed` / `ClientError`, noting no standalone local log file exists in workspace), records user-directed native Swift migration and AGY Keychain OAuth refresh write-back authority, records owner-approved `thermos` -> independent Codex review substitution (`decisions.tsv:7`), and records owner waiver of remaining Task 7 live steps (`decisions.tsv:11`). No self-approval or new worktree.

## 3. Close AGY diagnostics & Keychain OAuth refresh write-back — **常规任务** / coder

- [x] Verify/refine current outcome handling, documented login guidance, ambiguous 403 treatment, strict tuple, source precedence, proactive/401 pinned OAuth refresh, and user-requested atomic fail-closed Keychain write-back to exact `(service: "gemini", account: "antigravity")` (**implemented in native Swift `UsageLensKit/AgyNativeProbe.swift`**; zero runtime `python3` dependency, zero writes to local auth files).
- **Acceptance:** isolated synthetic cases cover missing/unreadable/malformed/denied/timeout/unknown nonzero/isolated HOME, expiry (`expiry_date`, `expiry`, `expires_at`, ms/sec/stringified-ms/RFC3339Nano) with proactive skew, expiry without client ID, successful/rejected refresh, invalid refresh expiry metadata fail-closed rejection, lossless unknown-field and `go-keyring-base64:` preservation on Keychain write-back, Keychain write-back failure modes (`.missing`/`.denied`/`.timeout`/`.nonzero`/`.rejected`/read-only) fail-closed handling, and bounded write timeout/single-flight/cancel-before-attach safety. No raw body, synthetic secret, Keychain enumeration, ACL widening, or auth-file write; guidance uses agy or verified agy acp --login, never agy login or borrowed Gemini clients.

## 4. Enforce final process environment — **常规任务** / coder

- [x] Apply design provider rules after inherited input, trusted injection and overrides (**enforced in native Swift `UsageLensKit/ProbeRunner.swift`**, routing Codex, AGY, Gemini, DeepSeek, and OpenCode natively without spawning `python3`).
- **Acceptance:** synthetic tests observe presence/absence booleans for every provider plus nil/unknown, future GEMINI_*/AGY_*, OAuth clients, both API keys, project aliases, ADC credential variables and conflicting overrides. Forbidden markers never reach child/output/UI; allowed own-provider settings/runtime essentials survive. Never dump real parent environment.

## 5. Add Gemini project context — **常规任务** / coder after scope approval

- [x] Implement trimmed GEMINI_PROJECT_ID > GOOGLE_CLOUD_PROJECT > GOOGLE_CLOUD_PROJECT_ID > server discovery and design's load/quota fields; reject numeric project numbers without echoing input (**implemented in native Swift `UsageLensKit/GeminiNativeProbe.swift`**).
- **Acceptance:** mocked request tests cover each precedence/conflict/blank/numeric case, local/manual OAuth, no project, discovered/missing project, 401 bounded refresh and 403 denial. Explicit project is not replaced; both API-key-only cases make zero OAuth quota requests. No onboarding, credential writes or real Workspace success inferred from mocks.

## 6. Retain complete automated evidence — **常规任务** / coder

- [x] Fix the prior native Swift blocking review findings (`DeepSeekNativeProbe` minimal `zstd` child env + watchdog/reap/exit validation; `ProbeRunner` real wall-clock timeout + `AgyNativeProbe` noninteractive `LAContext` & bounded single-flight Keychain + cooperative scan cancellation; `PinnedURLSessionTransport` streaming 1 MB cap + real `URLSession` redirect/chunked tests; checked numeric conversions & overflow-safe token accumulation; `DispatchSourceTimer` lifetime race in `ProbeRunner.swift` and `AgyNativeProbe.swift`) **and** implement user-requested native Swift 5.9+ AGY Keychain OAuth refresh write-back (`AgyNativeProbe.swift`, `NativeProbeSupport.swift`, `ProbeRunner.swift`, `AgyProviderTests.swift`, `NativeSafetyAndLifecycleTests.swift`) for exact `(service: "gemini", account: "antigravity")` with `expiry_date`/`expiry`/`expires_at` proactive skew, pinned `https://oauth2.googleapis.com/token` refresh, strict expiry metadata verification, lossless unknown-field & `go-keyring-base64:` preservation, round-trip pre-write verification, atomic in-place `SecItemUpdate`, zero writes to auth files, and fail-closed write-back error/timeout/single-flight handling. Ran focused (`30/30` in `AgyProviderTests|NativeSafetyAndLifecycleTests`, 0 warnings, exit 0) and full `swift test --package-path app` (`123/123`: 90 Kit + 33 UI, 0 warnings, exit 0), retaining complete sanitized output + reproducible dirty Swift tree digest/manifest in `openspec/changes/agy-auth-discovery-diagnostics/swift-test-evidence.md`. Subsequently validated all 4 dirty Python reference files (`probes/agy.py`, `probes/gemini.py`, `tests/test_agy.py`, `tests/test_gemini.py`) and full Python probe suite (`python3 -m unittest discover -s tests -p "test_*.py" -v`: `101/101` passed, 0 failures, 0 skips, exit 0 in 11.817s) without mutating frozen source files, retaining sanitized output + reproducible SHA-256 digests in `openspec/changes/agy-auth-discovery-diagnostics/python-test-evidence.md`.
- **Acceptance:** retain tested revision/dirty-build identity (with reproducible hashing recipe/manifest), command, exit, totals/failures/skips and full completion for both the native Swift suite (`swift-test-evidence.md`, 123/123) and the isolated Python reference suite (`python-test-evidence.md`, 101/101). Build/compiled bundles are not suite success; incomplete/timeout is not pass. Sanitize evidence before retention; no real-auth logs.

## 7. Packaged authentication lifecycle — **复杂任务** / tech_lead with owner

- [x] Follow design's protocol for packaged `app/dist/UsageLens.app` (`dev.usage-lens.UsageLens`, executable SHA-256 `b5d6ad75...`) live AGY verification (`login` confirmed by owner), with remaining interactive `logout`, `re-login`, `relaunch`, and manual legibility steps explicitly waived by owner (`decisions.tsv:11`, `packaged-lifecycle-evidence.md`); leave owner signed in.
- **Acceptance:** reduced secret-free evidence retained in `openspec/changes/agy-auth-discovery-diagnostics/packaged-lifecycle-evidence.md` with bundle/build metadata, boolean env-override absence, owner-confirmed `login` row, and explicit owner waiver rows (`waived-by-owner`) without overstating unexecuted live steps or recording credentials/emails/project IDs/screenshots.
- [x] Explicitly mark Gemini Workspace project-context support as `synthetic-only / waived-by-owner` pending real Workspace acceptance (`packaged-lifecycle-evidence.md`, `decisions.tsv:11`); no real Workspace success claimed.
- **Acceptance:** reduced evidence explicitly records `synthetic-only / waived-by-owner`; account/project values absent; API keys do not close this gate.

## 8. Independent review and closure — **常规任务** / reviewer then tech_lead

- [x] Freeze implementation and confirm coder exit; review full committed/uncommitted scope under owner-approved independent Codex review (`thermos` substitution recorded at `decisions.tsv:7`); reviewer writes `review_report.md` (`VERDICT: PASS`).
- **Acceptance:** `VERDICT: PASS` recorded in `review_report.md` by independent read-only Codex review (2026-11-22) with all mandatory evidence / recorded owner exceptions and zero blockers. Coordinator recorded acceptance, created local commit on `main`, returned `.orca-relay/state.json` to `IDLE` (`revision: 6`), and pushed to `origin/main` per explicit owner instruction.
