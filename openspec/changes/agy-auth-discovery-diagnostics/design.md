# Technical Design: Explainable AGY Authentication Discovery

## Current evidence

| Observation | Interpretation | Constraint |
| --- | --- | --- |
| `agy` is installed as a native macOS executable and `~/.gemini/antigravity-cli/` exists. | AGY has been used on this machine; session logs can be found. | Directory presence is not proof of an OAuth credential. |
| `~/.gemini/antigravity-cli/auth.json` is absent. | The existing file source cannot authenticate this installation. | Do not manufacture this file. |
| The current `agy.py` run yielded no account/quota windows but did yield local today-token data. | Local transcript discovery works; credential resolution did not produce usable credentials in the research environment. | The environment may not have the same Keychain entitlement/interaction context as the packaged app. |
| Existing resolver calls `security find-generic-password -s gemini -a antigravity -w` with a two-second timeout. | It uses a specific, bounded Keychain target. | Its current `None` return erases “missing” vs. “access denied” vs. “timeout”. |
| Prior fixture reports installed AGY `1.5.13` schema (`fixtures/agy-1.5.13-keychain-schema.json`); this research did not access the item. | Recorded tuple is `class: genp`, `service: "gemini"`, `account: "antigravity"`, encoding `go-keyring-base64:`. | Keep the single tuple; prior schema evidence does not prove current access from a packaged app. |
| Earlier research reports different daily Cloud Code responses with/without `User-Agent: antigravity`; underlying live evidence was not reproduced in this research. | Header is a compatibility observation, not an independently established public API guarantee or proof that every 403 means expired auth. | Retain pinned endpoints/header; verify synthetically and in packaged acceptance without recording response bodies. |

## Proposed model

Introduce an internal, secret-free `AGYCredentialDiscovery` result rather than returning only a credential-or-`None` value.

```text
environment override
        |
supported local auth files (allowlist)
        |
supported Keychain identifiers (allowlist)
        |
unconfigured diagnostic result
```

Each source attempt returns a non-secret outcome such as `available`, `missing`, `unreadable`, `malformed`, `denied`, `timeout`, `expired`, or `not-applicable`.  The object must never retain token text, token length, email, raw Keychain stderr, JSON payload, or filesystem content after it has made a decision.

`probes/agy.py` continues to keep credential material local to the authentication request.  It maps the final discovery outcome to a concise, redacted user warning.  The UI identifies the provider as **AGY**, and its empty state includes a provider-specific action: use the AGY account, unlock/re-authenticate through AGY as appropriate, then refresh.  It must never direct AGY users to paste credentials into Gemini settings.

## Supported-source policy

- Retain the existing supported sources: explicit `AGY_*` overrides for tests/development, `$AGY_AUTH_FILE`, `~/.gemini/antigravity-cli/auth.json`, and Keychain `(service: gemini, account: antigravity)`.
- Add another file or Keychain tuple only after a fixture that proves the AGY release uses it.  A fixture contains field names/types and a one-way secret-free outcome, never encoded or redacted real credential values.
- Stop after the known candidates; no directory recursion outside the designated AGY directory, no `security dump-keychain`, no wildcard Keychain enumeration, and no browser/SQLite inspection.

## UI and contract behavior

The public `usage-lens/probe@1` contract remains compatible.  Use the existing `warnings` / `error` strings for user text and optionally add a future, schema-versioned `diagnostics` field only after contract approval.  Do not overload `account.label` or invent a fake account.

The distinction between an ordinary user result and test/development isolation matters:

- When `HOME` differs from the login user's real home, report that real-Keychain discovery was intentionally skipped (without naming a home path).
- On a Keychain process failure, distinguish nonzero status, timeout, and malformed returned payload using generic text only.
- A server 401 after discovery is authentication rejection, not “no AGY installation”; a 403 may also mean project permission, policy, entitlement, or service denial. Do not assert expiration from 403 alone.

## Verification strategy

All auth tests use isolated homes, fake `security` executables, and synthetic credential payloads.  Tests assert absence of synthetic secret strings in every output channel.  A manual packaged-app check is required because sandboxed test terminals may not represent login-Keychain accessibility.

## Evidence-backed follow-up design (2026-11-22)

### Evidence and confidence

Read-only inspection covered AGENTS.md, this change and the earlier AGY usage spec, review_report.md, relay config/state/decisions, both probe resolvers and HTTP flows, and ProbeRunner environment construction. No real auth file, Keychain payload, environment secret value, transcript content, or raw runtime log was read for this research. No live quota call, login, logout, build, or suite execution is claimed.

Local `/Users/donhao/.local/bin/agy --version` returned `1.5.13`; `agy --help` has no top-level `login` subcommand; `agy help acp` documents `--login` as interactive Google login followed by exit. Its public help also identifies the daily Cloud Code endpoint and `.gemini`/`antigravity-cli` defaults. These commands only requested help/version. They do not establish usable credentials or OAuth refresh client availability.

Authoritative sources retrieved 2026-11-22:

1. [AGY 1.5.13 README](https://github.com/google-antigravity/antigravity-cli/blob/1.5.13/README.md), Authentication section: saved system-keyring session first, browser sign-in locally, authorization URL over SSH, and `/logout` for sign-out. [Versioned release](https://github.com/google-antigravity/antigravity-cli/releases/tag/1.5.13) identifies release commit `74b5ed6` and mentions ADC support. This pins the documented baseline, but does not publish the Keychain tuple/schema.
2. [Antigravity Authenticate](https://antigravity.google/docs/install/): current documentation describes silent native-keyring sign-in, browser fallback, API-key and ADC alternatives, and `/logout` clearing credentials/cache. This is a rolling document, not proof every described mode exists identically in 1.5.13. [CLI troubleshooting](https://antigravity.google/docs/cli/troubleshooting) describes locked/headless keyring failures and checking `agy` access in Keychain Access. Its friendly item name is not permission to guess new lookup identifiers. Do not automate its unlock/lock/settings commands or broaden ACLs.
3. [Gemini authentication](https://geminicli.com/docs/get-started/authentication/#set-your-google-cloud-project): Workspace and licensed Code Assist Google sign-in can require a Cloud project, enabled Gemini for Cloud API, and IAM permissions. Official precedence is `GOOGLE_CLOUD_PROJECT`, then `GOOGLE_CLOUD_PROJECT_ID`. This applies to Google OAuth/Code Assist as well as separate Vertex configuration. UsageLens does not load shell profiles or Gemini `.env` files, so a Finder-launched app may not inherit terminal exports. A configured app project or explicitly controlled launch environment is needed for packaged verification; never import a whole shell environment file.
4. [Official Gemini setup source](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/setup.ts), `setupUser` and `_doSetupUser`: resolves those project variables, rejects numeric project numbers, and supplies the selected project in `loadCodeAssist.cloudaicompanionProject` and `metadata.duetProject`. This rolling upstream source supports request semantics, not a stability guarantee for internal quota endpoints. UsageLens remains read-only and must not copy onboarding/enrollment calls.
5. [Google Gemini API-key documentation](https://ai.google.dev/gemini-api/docs/api-key): SDKs can use `GEMINI_API_KEY` or `GOOGLE_API_KEY`, with the latter taking precedence when both exist. These keys authenticate the Gemini API; their presence is not a Google OAuth access token, AGY account, or proof of Code Assist quota entitlement. Do not transfer that SDK precedence into OAuth quota credentials.

### Current implementation gaps

`probes/gemini.py:_resolve_credentials` reads `GEMINI_PROJECT_ID` only. `build_payload` bypasses `loadCodeAssist` when that project is present; otherwise it sends metadata only and uses a returned project for `retrieveUserQuota`. Neither probe consumes Google API-key variables. AGY independently uses `AGY_PROJECT_ID`; do not apply Gemini's project fallback to AGY without AGY-specific evidence.

`ProbeRunner.execute` copies the complete parent environment, removes only three Gemini variables for non-Gemini providers, and applies arbitrary overrides after filtering. Thus OAuth client credentials, API keys, future `GEMINI_*` variables, and late cross-provider overrides can cross provider boundaries. Existing AGY prefix removal is useful but does not close these other paths. This is subprocess exposure, not evidence of transmission to a quota host.

The fixture lacks OAuth client credentials; a refresh token alone cannot satisfy the current refresh helper's client-ID requirement. Keep bounded in-memory refresh when legitimately available; otherwise explain re-login. Never obtain missing clients/secrets from Gemini/browser assets. File overrides remain development compatibility sources, not an official AGY credential-file promise.

### Gemini project selection and requests

UsageLens precedence SHALL be nonempty trimmed `GEMINI_PROJECT_ID` (including the existing app account override), then `GOOGLE_CLOUD_PROJECT`, then `GOOGLE_CLOUD_PROJECT_ID`, then read-only server discovery. Preserve existing manual-token priority and zero-network gating when OAuth credentials are absent. Project selection supplies routing context, never authentication. Reject a numeric project number with fixed guidance that does not echo the supplied value.

With a selected project, perform read-only `loadCodeAssist` with both `cloudaicompanionProject` and `metadata.duetProject`, then use the selected project in `retrieveUserQuota.project`. Without one, retain metadata-only discovery and use a valid returned project. Do not silently replace a selected project or retry a permission failure against another project/account. Missing project/403 guidance should mention project setup/IAM where appropriate without inferring Workspace status from email or printing server bodies. Preserve bounded timeouts and at most one OAuth refresh; no onboarding, billing, or account mutation. This request-flow adjustment requires tech-lead scope/interface approval under AGENTS.md before coding.

### Environment boundary

Build the final environment from parent input, trusted provider injection, and validated overrides, then enforce provider scope before spawning `/usr/bin/env`. Non-Gemini probes receive no `GEMINI_*`; non-AGY probes receive no `AGY_*`; only DeepSeek receives `DEEPSEEK_API_KEY`. Current OAuth-only probes receive neither `GEMINI_API_KEY` nor `GOOGLE_API_KEY`, including Gemini itself. `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_PROJECT_ID` are permitted only for Gemini's project selection. Do not blanket-remove every `GOOGLE_*` variable: explicitly exclude credential-bearing `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CREDENTIALS`, and `CLOUDSDK_AUTH_ACCESS_TOKEN` from all current probes, which implement no ADC path. Future providers/auth modes require their own reviewed allowlist.

Overrides cannot bypass these rules; reject or omit cross-provider names deterministically without logging their values. Retain runtime essentials such as HOME/PATH/locale and required existing provider settings. Unknown provider/nil gets no managed auth variables. An arbitrary unrelated parent secret is not covered by prefix filtering; a broader minimal-environment migration is separate scope. Do not claim a universal secret sandbox.

### Safe packaged-app acceptance protocol

1. Coordinator first confirms serial handoff and implementation freeze. Build/test the intended revision, identify actual bundled probes and executable, record commit plus dirty-change/build identifier, macOS/AGY version, signing/sandbox mode and test timestamp. Use the real bundled app in the local user's graphical session, with test/manual token overrides absent; record absence as booleans only. A development shell success cannot substitute for this test.
2. Have the account owner complete AGY's supported login (`agy` browser flow, or locally verified `agy acp --login`), without terminal recording/screenshots containing account data. Keep OAuth URLs/codes, emails, token fields, project IDs and raw output out of artifacts. If Keychain prompts appear, the owner decides interactively; do not change ACLs, mark all applications trusted, or supply a password in argv. A denial produces an access diagnostic, never an “item missing” claim.
3. Launch the bundle normally, select AGY, explicitly refresh, and wait for completion within the configured provider budget plus UI scheduling allowance (target 30 seconds). Observe live windows/account presence as booleans/count only; local transcript tokens alone do not pass live authentication. Distinguish partial quota response from fully successful windows.
4. Only with the owner's controlled logout agreement, use `/logout` inside AGY itself. Do not delete Keychain items/files or revoke credentials through an invented UsageLens action. Quit/stop AGY at its signed-out state to prevent immediate silent/browser re-login. Explicitly refresh UsageLens and check that prior windows are cleared or visibly stale, with a fixed missing/rejected warning. An already-issued access token might survive upstream logout until expiry; if fresh quota still succeeds, mark logout acceptance inconclusive and investigate in-memory cache/in-flight work instead of claiming logout revokes every access token.
5. Owner re-authenticates through AGY, then explicitly refreshes UsageLens. Confirm recovery without manual token entry, no fabricated zero-percent windows, and no Gemini configuration instruction. Check Gemini's expected state separately; refresh-all may invoke Gemini, so “unchanged” means no credential/account mutation, not zero invocations. Relaunch the bundle and repeat refresh to detect process-only recovery. Leave the owner signed in.
6. Retain only build/version metadata and rows `stage, provider, pass/fail/inconclusive, account_present, window_count, warning_category, elapsed_seconds`. Stages are login, logout, re-login and app relaunch. No UI screenshot, console dump, credential value/length, auth URL, email, project ID, or raw HTTP/security log belongs in evidence. Cancellation/access denial is a recorded limitation, never a pass. Synthetic denied/timeout testing suffices; do not intentionally lock the user's Keychain.

### Remaining limitations and release gates

The current review is REJECT; no full Swift test pass or packaged authentication cycle was established here. Prior 93-test Python/build claims remain attributed to that review, not rerun results. Relay still records TAKEOVER revision 2; only tech_lead may correct the state/decisions and preserve original local-Coder failure evidence. Required `$thermos` reviewer skill was unavailable per the review; coordinator must restore it or obtain explicit owner resolution. No implementation acceptance can be inferred from this research or its checked documentation task. Official docs do not guarantee public stability of internal quota endpoints, exact Keychain serialization, or immediate upstream token revocation on logout.

## Native Swift Runtime Hardening (2026-11-22)

Following the user-authorized native Swift migration of all provider probes (`CodexNativeProbe`, `AgyNativeProbe`, `GeminiNativeProbe`, `DeepSeekNativeProbe`, `OpenCodeNativeProbe`, `NativeProbeSupport`, `ProbeRunner`), the four blocking implementation defects identified in independent review were addressed in native Swift without introducing third-party dependencies or editing Python files:

1. **DeepSeek `zstd` child environment isolation (`DeepSeekNativeProbe.minimalZstdEnvironment`)**: Every `zstd` subprocess sets an explicit minimal `Process.environment` allowlist (`PATH`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR`, defaulting `PATH` to `/usr/bin:/bin`). Neither inherited parent environment variables nor provider credentials (including `DEEPSEEK_API_KEY`, `GEMINI_*`, `AGY_*`, `CODEX_*`, Google API keys, Google project aliases, or ADC variables) are passed to `zstd`. Verified by spawning an actual test child executable under synthetic parent injections and asserting only presence booleans.
2. **Real bounded cancellation/timeout and subprocess watchdog**:
   - `ProbeRunner.runWithTimeout` uses an unstructured detached `Task` raced against a `DispatchSourceTimer` via a one-shot continuation and `withTaskCancellationHandler`, returning promptly at wall-clock deadline instead of blocking inside `withTaskGroup` teardown when an underlying operation is noncooperative.
   - `SystemAgyKeychainReader.buildQuery` attaches `LAContext` with `interactionNotAllowed = true` (`kSecUseAuthenticationContext`) alongside the exact `(service: "gemini", account: "antigravity")` query so interactive Keychain auth fails closed (`errSecInteractionNotAllowed` -> `.denied`). **macOS platform limitation**: Apple's `SecItem.h` documents that `LAContext.interactionNotAllowed` enforces noninteractive failure on Data Protection Keychain items while legacy file-based login Keychain ACL prompts/IPC are not directly interruptible inside the process. To bound wall-clock execution fail-closed even if a legacy Keychain call blocks, `AgyNativeProbe` dispatches Keychain lookups off the Swift Concurrency cooperative pool with a 2-second wall-clock timeout (`defaultKeychainTimeoutSeconds`), `Task` cancellation propagation, and a single-flight gate (`AgyKeychainSingleFlightGate`) that fails closed immediately with `.timeout` while a prior call remains stuck, preventing thread pileup.
   - `DeepSeekNativeProbe.decompressZstd` runs asynchronously with `terminationHandler` + `DispatchGroup` (never calling `Process.waitUntilExit()` on cooperative threads), a bounded pipe drainer capped at `zstdMaxDecompressedBytes`, per-file timeout clamped by remaining `spendScanBudgetSeconds`, `SIGTERM` -> 0.25s bounded grace -> `SIGKILL` escalation -> confirmed reap, and strict `exitStatus == 0` validation.
   - `NativeProbeSupport.readLinesReverse` and Codex/AGY/DeepSeek/Gemini scan/network paths check `Task.isCancelled` cooperatively.
3. **Streaming 1 MB HTTP response cap (`PinnedURLSessionTransport`)**: Replaced buffered `URLSession.data(for:)` with a `URLSessionDataDelegate` (`StreamingHTTPDelegate`) that rejects non-official URLs, 3xx redirects (`willPerformHTTPRedirection` + `didReceive response`), and declared `Content-Length` / `expectedContentLength` > `maxBytes` (including overflowing decimal strings) before reading body bytes, enforces the cumulative byte cap incrementally inside `didReceive data` without appending oversized chunks, cancels the `URLSessionDataTask` and invalidates the session immediately, and propagates Swift `Task` cancellation via `withTaskCancellationHandler`. Verified with real `URLSession` + `URLProtocol` transport tests.
4. **Checked numeric conversions and overflow-safe accumulation**: Replaced trapping `Int(d)`, `Int(minutes * 60)`, and unchecked `+=` in `NativeProbeSupport`, `CodexNativeProbe`, `AgyNativeProbe`, `DeepSeekNativeProbe`, `ProbeContract`, `ProbeRunner`, and `Formatting` with `checkedInt(fromTruncating:)`, `nonNegativeInt(_:)` (handling IEEE-754 `Double(Int.max)` rounding to `2^63`, `NSDecimalNumber`, `UInt64`, and `1e100`), `checkedPositiveIntSeconds(_:multiplier:)`, and `checkedAdd(_:_:)`. Malformed or overflowing token/duration inputs degrade honestly to `nil` / default window duration with diagnostic warnings instead of trapping the app process.

Packaged bundle verification (Task 7), build/package/restart, legacy Python reference file verification, and coordinator-owned relay/thermos closure remain open outside this Swift coder pass.

## Native Swift AGY Keychain OAuth Refresh Write-Back (2026-11-22)

Per explicit user instruction, this section supersedes the earlier zero-Keychain-write constraint for AGY Keychain-origin credentials while preserving zero-write semantics for local auth files and isolated test homes.

### Scope & Security Invariants

1. **Narrowly scoped Keychain write abstraction (`AgyNativeProbe.swift`)**:
   - Introduces `AgyKeychainWriteResult` (`.updated`, `.missing`, `.denied`, `.timeout`, `.nonzero`, `.rejected`) and `AgyKeychainWriting` (`updateGenericPassword(service:account:payload:)`).
   - `SystemAgyKeychainReader` conforms to both `AgyKeychainReading` and `AgyKeychainWriting` and enforces `isAllowedTuple(service: "gemini", account: "antigravity")` before touching `Security.framework`.
   - Writes execute exclusively via atomic in-place `SecItemUpdate` updating **only** `kSecValueData` (`buildUpdateAttributes`), attaching `LAContext(interactionNotAllowed: true)` (`buildUpdateQuery`) without `kSecMatchLimit` or `kSecReturnData`. It never calls `SecItemAdd`, `SecItemDelete`, wildcard queries, or ACL/accessibility mutations. If the item was removed (e.g., via `agy /logout`), `errSecItemNotFound` maps fail-closed to `.missing` without recreating the item.
   - Both async Keychain reads (`readKeychainBoundedAsync`) and async Keychain updates (`updateKeychainBoundedAsync`) share `runKeychainBoundedAsync`, the 2-second wall-clock `DispatchSourceTimer` (with atomic activate-under-lock lifetime guarantees), `Task` cancellation propagation, and `AgyKeychainSingleFlightGate`.
2. **Expiry checking & proactive skew**:
   - Supports `expiry_date`, `expiry`, and `expires_at` inside nested `token` objects and flat root payloads, parsing epoch milliseconds/seconds (numeric or stringified), ISO8601/RFC3339 (including Go `RFC3339Nano` sub-millisecond timestamps), and explicit `0` as expired.
   - `NativeProbeSupport.parseExpiryEpoch` evaluates numeric values/strings before `ProbeDate.parse` so stringified millisecond timestamps (e.g. `"1763800000000"`) are normalized to seconds rather than misread as raw seconds.
   - Triggers proactive refresh when `access_token` is absent or `expiryEpoch <= now + proactiveRefreshSkewSeconds` (`60.0` seconds), and preserves bounded single reactive refresh on HTTP `401`.
3. **Pinned refresh & strict expiry metadata verification**:
   - Refreshes exclusively via pinned `https://oauth2.googleapis.com/token` (`PinnedURLSessionTransport`, no redirects, 1 MB streaming cap, never borrowing `GEMINI_OAUTH_CLIENT_*`).
   - Validates `access_token` (non-empty, no ASCII control characters), optional rotated `refresh_token` (non-empty, no control characters), and expiry metadata (`expires_in` within `1...31_536_000` seconds and/or explicit future `expiry_date`/`expiry`/`expires_at` within the same upper bound). Missing, zero, negative, boolean, non-numeric, overflowing, or past expiry metadata fails closed with zero Keychain writes.
4. **Lossless atomic payload update & fail-closed persistence**:
   - Write-back executes **only** when credentials originated from Keychain (`origin == .keychain`, which already requires non-isolated `HOME` and exact tuple). Credentials from `AGY_ACCESS_TOKEN`, `$AGY_AUTH_FILE`, or `~/.gemini/antigravity-cli/auth.json` never write to auth files and never write to Keychain.
   - Updates `access_token`, rotated `refresh_token` (retaining existing `refresh_token` when omitted), `token_type`/`id_token`/`scope` when returned, `expires_in` when present, and all existing non-null expiry keys while preserving their original representation (`go-keyring-base64:` wrapper vs raw JSON, nested `token` vs flat root, ms vs sec vs RFC3339 UTC) and all unknown root/token fields. Environment-injected OAuth client variables are never persisted into the Keychain payload.
   - Serializes deterministically (`[.sortedKeys, .withoutEscapingSlashes]`) and performs a mandatory round-trip decode self-check (`access_token`, `refresh_token`, and future `expiryEpoch > now`) before calling `SecItemUpdate`.
   - Any serialization, self-check, or Keychain write-back failure (`.missing`, `.denied`, `.timeout`, `.nonzero`, `.rejected`, or read-only writer) fails closed immediately without proceeding to Cloud Code quota calls, emitting only fixed, `SecretRedactor`-sanitized Chinese diagnostics free of raw tokens, `Gemini` references, or `agy login`.
5. **macOS platform caveat**:
   - `SecItemUpdate` performs a single atomic in-place update of `kSecValueData` on macOS without a compare-and-swap predicate on previous value bytes; concurrent external writers (e.g., an independent `agy` CLI refresh) follow last-writer-wins semantics, while in-process Keychain reads and writes are serialized by `AgyKeychainSingleFlightGate` and bounded against legacy login-Keychain IPC stalls.

