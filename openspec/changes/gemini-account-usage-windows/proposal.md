# Proposal: Gemini Account-Gated 5-Hour & 7-Day Usage Windows

## Problem Statement

`UsageLens` already registers `ProviderCatalog.gemini` (`id: "gemini"`, `displayName: "Gemini"`, `probeRelativePath: "probes/gemini.py"`) and includes `"gemini"` in `ProviderCatalog.defaultActiveIDs = ["codex", "gemini", "opencode"]` (`app/Sources/UsageLensKit/Provider.swift`). However, Gemini is currently unimplemented:

1. **Missing Probe**: `probes/gemini.py` does not exist in the repository. On launch and every refresh, `ProbeRunner` returns `isMissingProbe: true` with `"未安装探针 probes/gemini.py"`, causing the Gemini tab to show a generic `"未提供账号"` header and `"无数据 / 未安装探针 probes/gemini.py"` card.
2. **No Gemini Account Configuration**: `SettingsPanelView.swift` and `ProbeRunner.swift` only support credential configuration and Keychain injection for DeepSeek (`requiresAPIKey` / `DeepSeekAPIKeyStore`). There is no way for users to provide, validate, persist, update, or clear a Gemini account.
3. **No 5-Hour / 7-Day Usage Display**: Even when a user has a Gemini account (Google Cloud Code Assist / Gemini CLI OAuth account), `UsageLens` cannot query or display Gemini's 5-hour (`5 小时`) and 7-day (`7 天`) usage windows.

## User Requirement

> gemini需要提供账号才能显示7天和5小时的使用量。

## Current Behavior vs. Desired Behavior

| Aspect | Current Behavior | Desired Behavior |
|---|---|---|
| **Unconfigured Gemini tab** | Shows `"无数据"` with `"未安装探针 probes/gemini.py"` (status `.missing`). | Shows an explicit account-required empty state (`"需要提供 Gemini 账号"` + guidance + `"前往配置"` button), makes **zero network requests**, and never fabricates `0%` usage. |
| **Settings (`SettingsPanelView`)** | Clicking Gemini in the provider list does nothing (`disabled(!provider.requiresAPIKey)`). | Clicking Gemini expands the Gemini Account configuration section where the user can enter their **account email** and **OAuth access token**, validate them against Google's official quota endpoint before saving, view the saved account email (with masked token), or clear/delete the account. |
| **Configured Gemini tab** | Never shows windows. | Displays the configured Gemini account label (and plan tier when available) in the header, plus **5 小时 (`5h`)** and **7 天 (`7d`)** `WindowRowView` cards with used percentage, progress bar, reset countdown, and `服务端` basis label. |
| **Credential errors / expiry** | N/A | Invalid/expired tokens (HTTP 401/403), rate limits (429), network errors, or redirect violations produce clear, redacted Chinese error messages; previous values enter `.stale` (dimmed) or `.failed` when no prior data exists, never `0%`. |

## Goals

1. **Explicit Account Gate**: Enforce that Gemini requires a user-provided account before fetching or displaying 5-hour and 7-day usage windows. When no account is configured, `probes/gemini.py` makes zero network connections and returns `windows: []` with an explicit guidance warning, and `PanelView` renders a dedicated needs-account state with a shortcut to Settings.
2. **Secure Account Storage & Validation**: Add `GeminiAccountStore` in `UsageLensKit` backed by macOS login Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), validating candidate credentials via `probes/gemini.py` before saving, never displaying stored token plaintext in UI, and injecting credentials exclusively into the Gemini probe subprocess environment.
3. **Official-Endpoint Gemini Probe (`probes/gemini.py`)**: Implement a stdlib-only Python 3.9+ probe conforming strictly to `usage-lens/probe@1` that queries Google's official Cloud Code Assist endpoints (`https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`), maps quota buckets into canonical `5h` (`5 小时`, `18000s`) and `7d` (`7 天`, `604800s`) windows, and strictly enforces anti-redirect, host/scheme pinning, timeout, and secret redaction rules.
4. **Seamless UI & Theme/Scaling Integration**: Integrate Gemini account configuration into `SettingsPanelView` and needs-account / window rendering into `PanelView`, fully compatible with `DisplayScaleMetrics` (`0.85x–1.60x`) and all three themes (`tech`, `anime`, `system`).
5. **Deterministic Testing**: Cover Python probe behavior (offline/no-account, 5h+7d parsing, partial windows, expired/out-of-range/NaN values, HTTP 401/403/429/5xx, 302 redirect rejection, secret redaction, read-only filesystem) and Swift Kit/UI behavior (Keychain store abstraction, `ProbeRunner` env isolation, `SecretRedactor` Google token patterns, `ProviderReducer`, `PanelView` & `SettingsPanelView` offscreen rendering).

## Non-Goals

- **Silent auto-reading or mutating external CLI OAuth files**: `UsageLens` will NOT silently harvest or refresh `~/.gemini` / external OAuth refresh tokens without the user explicitly providing their Gemini account in Settings (preventing token refresh races and honoring the explicit account-gate requirement).
- **Interactive browser OAuth login flow**: Full OAuth client-ID/PKCE browser sign-in is out of scope for v1; users provide their account email and OAuth access token in Settings (or via `GEMINI_ACCOUNT_EMAIL` / `GEMINI_ACCESS_TOKEN` env vars during development).
- **Multi-account switching**: Consistent with `docs/REQUIREMENTS.md`, `UsageLens` manages one configured Gemini account at a time (updating or deleting replaces/clears it).
- **Fabricating missing windows**: If the upstream response only includes one of `5h` or `7d` (or neither), `probes/gemini.py` reports only real server values plus a warning—never inventing `0%`.
- **Modifying Codex, DeepSeek, or OpenCode behavior**: Existing providers remain unchanged.

## Security & Privacy Considerations

- **Keychain-only secret persistence**: Gemini OAuth access tokens are stored exclusively in macOS login Keychain (`service: "dev.usage-lens.gemini"`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), never in `UserDefaults`, plists, logs, or temporary files.
- **Process isolation**: `ProbeRunner` injects `GEMINI_ACCOUNT_EMAIL` and `GEMINI_ACCESS_TOKEN` (and optional `GEMINI_PROJECT_ID`) **only** when running `ProviderCatalog.gemini`, never into `codex`, `deepseek`, or `opencode` probe processes.
- **Strict network boundary**: `probes/gemini.py` only contacts `https://cloudcode-pa.googleapis.com` (port 443), disables all HTTP redirects (`_RejectRedirect`), verifies final `response.geturl()`, caps response reads at `1 MB`, and enforces a `3s` HTTP timeout.
- **Defense-in-depth redaction**: Both `probes/gemini.py` and `UsageLensKit.SecretRedactor` redact Google OAuth tokens (`ya29....`, `1//...`), `Bearer ...`, `key/token/secret=...`, and long opaque strings before any message reaches stdout, stderr, UI, or `USAGE_LENS_DEBUG_SUMMARY`.
- **Read-only probe**: `probes/gemini.py` writes zero files to disk.
