# Implementation Tasks: gemini-account-usage-windows

## 1. Python Gemini Probe (`probes/gemini.py`)
- [ ] Create `probes/gemini.py` (Python 3.9+ stdlib-only, executable, `usage-lens/probe@1`):
  - Implement strict CLI argument handling (no args or `--json`; unknown args exit `2` with JSON `error`).
  - Implement account gate: when `GEMINI_ACCESS_TOKEN` is missing/empty, make **zero** network calls and exit `0` with `windows: []`, `account: {"label": null, "plan": null}`, `error: null`, and warning `"请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"`.
  - Implement strict network client:
    - `_RejectRedirect(urllib.request.HTTPRedirectHandler)` refusing all 3xx redirects.
    - `is_official_url(url)` pinned strictly to `https://cloudcode-pa.googleapis.com` (default port 443).
    - `3.0s` timeout and `1 MB` response byte cap.
  - Implement `loadCodeAssist` (`POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`) for optional project ID (`cloudaicompanionProject`) and plan tier (`currentTier`) discovery when `GEMINI_PROJECT_ID` is not set.
  - Implement `retrieveUserQuota` (`POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`) and bucket normalization into canonical `5h` (`5 小时`, `18000s`) and `7d` (`7 天`, `604800s`) windows (`basis: "server"`):
    - Classify buckets by explicit duration fields or fallback `resetTime - now` delta.
    - Convert `remainingFraction` (`0..1`) or `used_percent` (`0..100`) with strict finite/range checks (invalid/NaN → `null` + warning, `allow_nan=False`).
    - Aggregate multiple model buckets per window conservatively (highest `used_percent`).
    - Set `expired: true` + warning when `resetTime < now`.
    - Emit honest warnings when one or both windows are missing (never fabricate `0%`).
  - Map HTTP 401/403/429/5xx, redirect, timeout, network, and JSON errors to clear Chinese `error` messages and non-zero exit code.
  - Implement secret redaction (`ya29.*`, `1//*`, `Bearer *`, `sk-*`, 32+ char tokens) on all warnings, errors, and stderr logs.

## 2. Core Credential & Runner Support (`app/Sources/UsageLensKit/`)
- [ ] Update `app/Sources/UsageLensKit/Provider.swift`:
  - Add `requiresAccount: Bool = false` and computed `requiresCredentials: Bool` to `Provider`.
  - Set `requiresAccount: true` on `ProviderCatalog.gemini`.
- [ ] Create `app/Sources/UsageLensKit/GeminiAccountStore.swift`:
  - Define `GeminiAccount` (`email`, `accessToken`, `projectID`), `GeminiAccountStoreError`, and testable `GeminiKeychainStorage` protocol (defaulting to macOS login Keychain `service: "dev.usage-lens.gemini"`, `account: "oauth-account"`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
  - Implement `hasSavedAccount`, `savedAccountEmail()`, `load()`, `save(email:accessToken:projectID:)`, `delete()`, and `validationMessage(email:accessToken:projectID:runner:)` (validates via `ProbeRunner` `environmentOverrides` before writing to Keychain).
- [ ] Update `app/Sources/UsageLensKit/ProbeRunner.swift`:
  - Inject `GEMINI_ACCOUNT_EMAIL`, `GEMINI_ACCESS_TOKEN`, and optional `GEMINI_PROJECT_ID` from `GeminiAccountStore.load()` **exclusively** when `provider?.id == ProviderCatalog.gemini.id`.
  - Support optional injectable credential loaders for deterministic unit tests without touching the host Keychain.
- [ ] Update `app/Sources/UsageLensKit/SecretRedactor.swift`:
  - Add redaction rules for Google OAuth access tokens (`ya29\.[A-Za-z0-9._-]+`) and refresh tokens (`1//[A-Za-z0-9._-]{16,}`).

## 3. UI Integration (`app/Sources/UsageLensUI/`)
- [ ] Update `app/Sources/UsageLensUI/PanelView.swift`:
  - Pass `showSettings` into `ProviderDetailView`.
  - Add explicit needs-account empty card when `state.provider.requiresAccount` and no account/windows/error are present: `"需要提供 Gemini 账号"`, guidance text mentioning 5-hour and 7-day usage, and a `"前往配置"` button invoking `showSettings()`.
  - Ensure all new elements scale with `@Environment(\.displayScaleMetrics)` and adapt to `tech`, `anime`, and `system` themes.
- [ ] Update `app/Sources/UsageLensUI/SettingsPanelView.swift`:
  - Generalize `expandedKeyProviderID` to `expandedCredentialProviderID` supporting both `requiresAPIKey` (DeepSeek) and `requiresAccount` (Gemini).
  - Add Gemini row icon (`person.crop.circle` / `person.crop.circle.badge.checkmark`) and accessibility label `"配置 Gemini 账号"`.
  - Add `geminiAccountSettings(for:)` section supporting:
    - Unconfigured state: email `TextField`, masked token `SecureField`, `"验证并保存"` button with loading state and redacted error status.
    - Configured state: displays saved account email + disabled masked token `"****************"` + destructive `"删除"` button (never echoes token plaintext).
    - Calls `onAPIKeyChange()` (or `onCredentialChange()`) on save and delete so `UsageStore.refresh()` updates the Gemini tab immediately.
  - Add optional test-injection parameters on `SettingsPanelView.init` so UI/snapshot tests do not read the live Keychain.

## 4. Automated Tests (`tests/` & `app/Tests/`)
- [ ] Create `tests/test_gemini.py`:
  - Test unconfigured/no-account exit `0`, `windows == []`, guidance warning, zero network calls, zero files written.
  - Test valid `loadCodeAssist` + `retrieveUserQuota` returning both `5h` and `7d` windows, plus multi-bucket highest-usage aggregation.
  - Test partial window availability (no fabricated `0%`), expired windows, out-of-range/NaN values (`strict_loads`).
  - Test HTTP 401/403/429/500, timeout, malformed JSON, and `LocalServer` 302 redirect rejection (no `Authorization` leak).
  - Test secret redaction (`ya29.` and long tokens never appear in stdout/stderr) and unknown CLI arg exit `2`.
- [ ] Update `app/Tests/UsageLensKitTests/KitTests.swift` (or add `GeminiAccountTests.swift`):
  - Test `ProviderCatalog.gemini` flags, `GeminiAccountStore` CRUD & validation with in-memory storage and temp probe script, `ProbeRunner` env isolation, `SecretRedactor` Google token patterns, and `ProviderReducer` / `Tension.mostTense` transitions (unconfigured → configured 5h/7d → cleared → auth expired).
- [ ] Update `app/Tests/UsageLensUITests/PanelRenderTests.swift` (and/or `DisplayScalingTests.swift`):
  - Add `ImageRenderer` offscreen rendering tests for `PanelView` (Gemini needs-account, configured 5h+7d windows, auth error) and `SettingsPanelView` (Gemini unconfigured & configured) across display scales.

## 5. Local Verification Commands
- [ ] Run Python probe test suite (including new `test_gemini.py` and existing Codex/DeepSeek suites):
  ```bash
  python3 -m unittest discover -s tests -v
  ```
- [ ] Run Gemini probe CLI smoke check with isolated empty `HOME` (no account):
  ```bash
  HOME="$(mktemp -d)" python3 probes/gemini.py | python3 -m json.tool
  ```
- [ ] Run Swift build and full Swift test suite:
  ```bash
  cd app && swift build && swift test
  ```
- [ ] Verify `git status` and `git diff` contain only intended changes with no real secrets or debug artifacts.
