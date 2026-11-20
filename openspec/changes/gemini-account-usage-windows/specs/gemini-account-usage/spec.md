# Behavioral Specification: Gemini Account-Gated 5-Hour & 7-Day Usage Windows

## Requirement 1: Unconfigured / No Gemini Account State

When no Gemini account is configured (neither saved in Keychain nor provided via environment variables):

### Scenario 1.1: Probe behavior with no account
- **Given** neither `GEMINI_ACCESS_TOKEN` nor `GEMINI_ACCOUNT_EMAIL` is set (or `GEMINI_ACCESS_TOKEN` is empty/whitespace).
- **When** `probes/gemini.py` runs (with no args or `--json`).
- **Then** the probe exits with code `0` and emits a single strict JSON line matching `usage-lens/probe@1`:
  - `provider == "gemini"`
  - `windows == []`
  - `account == {"label": null, "plan": null}` (or `label` set if only email was supplied without token)
  - `balance == null`, `spend == null`, `usage == null`, `error == null`, `stale == false`
  - `warnings` contains a clear Chinese guidance message stating that a Gemini account must be provided to view 5-hour and 7-day usage (e.g., `"请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"`).
- **And** the probe makes **zero** outbound network requests and writes **zero** files.

### Scenario 1.2: PanelView needs-account empty state
- **Given** the user selects the `Gemini` tab in `PanelView` and no Gemini account is configured (`windows` is empty, `accountLabel == nil`, `failureReason == nil`, `isMissingProbe == false`).
- **When** `PanelView` renders `ProviderDetailView`.
- **Then** the header shows `"未提供账号"`.
- **And** the body renders an explicit account-required card (NOT `"未安装探针"`, NOT `0%` progress bars) with:
  - Title `"需要提供 Gemini 账号"`
  - Explanation `"请在配置中提供 Gemini 账号，以查看 5 小时与 7 天使用量"`
  - A `"前往配置"` button that invokes `showSettings()`.
- **And** `Tension.mostTense` excludes Gemini (menu bar does not display a Gemini percentage).

---

## Requirement 2: Configuring, Updating, and Clearing a Gemini Account in Settings

Users manage their Gemini account from `SettingsPanelView`, backed by `GeminiAccountStore` in macOS login Keychain.

### Scenario 2.1: Expanding Gemini account configuration
- **Given** `Gemini` is in the active provider list in `SettingsPanelView`.
- **When** the user clicks the `Gemini` row in the `"模型厂商"` section.
- **Then** the Gemini account configuration section expands below the divider (collapsing any other expanded provider credential section).
- **And** if no account is saved, it shows:
  - Account input (`TextField` for email / account identifier, e.g., `user@gmail.com`)
  - Access token input (`SecureField`, masked, never echoing plaintext)
  - Optional Project ID input (or auto-discovered via `loadCodeAssist`)
  - A `"验证并保存"` button (disabled while email or token is blank, or while verification is in progress).

### Scenario 2.2: Pre-save credential validation
- **Given** the user enters a Gemini account email and candidate OAuth access token and clicks `"验证并保存"`.
- **When** `GeminiAccountStore.validationMessage(email:accessToken:runner:)` runs `probes/gemini.py` with temporary subprocess `environmentOverrides`.
- **Then**:
  - **If validation succeeds** (`report.failure == nil` and `report.envelope` is valid with at least one server usage window or verified quota response):
    - The account email and access token are saved to macOS login Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
    - Draft token text is cleared from memory/UI state.
    - The settings UI updates to the saved state (showing the saved account email + masked token `"****************"` + `"删除"` button).
    - `onCredentialChange()` triggers `store.refresh()` so the Gemini tab immediately loads 5h and 7d usage.
  - **If validation fails** (e.g., empty email/token, HTTP 401/403, network error, redirect blocked):
    - Nothing is written to Keychain.
    - A redacted Chinese failure message (`"验证失败：..."`) is displayed in orange.

### Scenario 2.3: Saved account display (no secret echo)
- **Given** a Gemini account is saved in Keychain.
- **When** the user opens the Gemini configuration section in `SettingsPanelView`.
- **Then** the UI displays the saved account email (non-secret label) and a disabled masked field `"****************"` for the token, plus a destructive `"删除"` button.
- **And** the raw access token is NEVER loaded into or displayed in any SwiftUI view state or text field.

### Scenario 2.4: Clearing / deleting the Gemini account
- **Given** a Gemini account is saved in Keychain and the Gemini tab currently displays 5h and 7d usage windows.
- **When** the user clicks `"删除"` in `SettingsPanelView`.
- **Then** both the account email and access token are deleted from Keychain.
- **And** `store.refresh()` runs immediately, `probes/gemini.py` returns the unconfigured envelope (`account.label == null`, `windows == []`, guidance warning), and `ProviderReducer` replaces the previous envelope so **no prior account's 5h/7d usage remains visible**.

---

## Requirement 3: Fetching and Displaying Gemini 5-Hour & 7-Day Usage Windows

Once a valid Gemini account is provided, `probes/gemini.py` fetches quota data and `PanelView` displays 5-hour and 7-day usage windows.

### Scenario 3.1: Valid account with both 5h and 7d windows
- **Given** `GEMINI_ACCOUNT_EMAIL` (`"user@gmail.com"`) and a valid `GEMINI_ACCESS_TOKEN` are provided to `probes/gemini.py`.
- **When** `loadCodeAssist` returns project/tier metadata (e.g., `cloudaicompanionProject`, `currentTier.id: "pro"`) and `retrieveUserQuota` returns buckets covering a 5-hour window and a 7-day window.
- **Then** `probes/gemini.py` exits `0` and emits valid `usage-lens/probe@1` JSON containing:
  - `account: {"label": "user@gmail.com", "plan": "pro"}`
  - `windows` containing:
    - `{"id": "5h", "label": "5 小时", "used_percent": <0..100>, "window_seconds": 18000, "resets_at": "<UTC ISO8601>", "expired": <bool>, "basis": "server"}`
    - `{"id": "7d", "label": "7 天", "used_percent": <0..100>, "window_seconds": 604800, "resets_at": "<UTC ISO8601>", "expired": <bool>, "basis": "server"}`
  - `stale: false`, `error: null`.
- **And** `PanelView` displays:
  - Header with `"user@gmail.com"` and plan pill `"Pro"`
  - Two `WindowRowView` cards: `"5 小时"` and `"7 天"`, each with `已用 XX%`, progress bar, reset countdown, and `"服务端"` label.
- **And** `Tension.mostTense` considers Gemini's non-expired, non-stale `5h` and `7d` windows alongside other active providers.

### Scenario 3.2: Multiple model buckets within the same window
- **Given** `retrieveUserQuota` returns multiple model buckets (e.g., `gemini-2.5-pro` with `remainingFraction: 0.35` and `gemini-2.5-flash` with `remainingFraction: 0.80`) mapped to the same window (`5h` or `7d`).
- **When** `probes/gemini.py` aggregates buckets for that window.
- **Then** it selects the most constrained bucket (highest `used_percent`, i.e., `65.0%` from `remainingFraction: 0.35`) and uses that bucket's `resets_at`, so the user sees the tightest quota pressure.

### Scenario 3.3: Partial window availability (e.g., only 5h or only 7d returned)
- **Given** `retrieveUserQuota` returns data for only one of the two windows (e.g., only `5h` buckets, no `7d` buckets).
- **When** `probes/gemini.py` builds the payload.
- **Then** `windows` includes only the real window returned by the server, and `warnings` explains which window was not returned (e.g., `"Gemini 接口未返回 7 天配额窗口"`).
- **And** the probe NEVER fabricates `0%` for the missing window.

### Scenario 3.4: Out-of-range / NaN / expired window values
- **Given** a quota bucket contains an invalid `remainingFraction` (`< 0`, `> 1`, `NaN`, or non-numeric) or a `resetTime` already in the past.
- **When** `probes/gemini.py` normalizes the bucket.
- **Then**:
  - Invalid `remainingFraction` maps to `used_percent: null` + a warning, and stdout remains strictly valid JSON (`allow_nan=False`).
  - Past `resetTime` sets `expired: true` + a warning, and `WindowRowView` renders `"窗口已过期..."` instead of a negative countdown.

---

## Requirement 4: Error Handling, Network Security, and Secret Redaction

### Scenario 4.1: Invalid or expired account credentials (HTTP 401 / 403)
- **Given** a configured Gemini account whose OAuth access token is invalid or expired.
- **When** `probes/gemini.py` calls the official endpoint and receives HTTP `401` or `403`.
- **Then** `probes/gemini.py` exits non-zero and emits valid JSON with:
  - `windows: []`
  - `error`: clear Chinese message instructing the user to update their Gemini account in Settings (e.g., `"Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"`).
- **And** `ProviderReducer` transitions to `.stale` (dimmed previous values + orange banner) if prior data exists, or `.failed` (explicit error card) if no prior data exists.

### Scenario 4.2: Rate limiting (HTTP 429), server errors (5xx), and network/timeout errors
- **Given** the upstream API returns HTTP `429`, `5xx`, invalid JSON, oversized body (`> 1MB`), or times out (`> 3s`).
- **When** `probes/gemini.py` handles the failure.
- **Then** it emits valid JSON with a human-readable Chinese `error` message, never crashes with an unhandled traceback, and respects the `3s` timeout.

### Scenario 4.3: Redirect rejection & official domain pinning
- **Given** the endpoint responds with HTTP `301`/`302`/`303`/`307`/`308` (e.g., redirecting to a third-party host).
- **When** `probes/gemini.py` sends a request with `Authorization: Bearer <token>`.
- **Then** `_RejectRedirect` aborts the redirect without sending the `Authorization` header to the redirect target, and `probes/gemini.py` reports a security error (`"已按安全策略拒绝跟随"`).

### Scenario 4.4: Secret redaction & process isolation
- **Given** a Google OAuth token (`ya29.a0AfB_by...`, `1//0e...`, `Bearer ...`, or any 32+ char token) appears in an error, warning, or stderr output.
- **When** `probes/gemini.py` emits output and `ProbeRunner` / `SecretRedactor` processes `ProbeReport` or `UsageStore.debugSummaryLine()`.
- **Then** all token strings are redacted (`[redacted]` / `***`) before reaching stdout, stderr, UI views, or debug logs.
- **And** `ProbeRunner` NEVER injects `GEMINI_ACCESS_TOKEN` or `GEMINI_ACCOUNT_EMAIL` into `codex`, `deepseek`, or `opencode` probe subprocesses.

---

## Requirement 5: UI Scaling & Theme Compatibility

### Scenario 5.1: DisplayScaleMetrics and themes
- **Given** `PanelView` (showing Gemini needs-account card, configured 5h+7d windows, or error state) and `SettingsPanelView` (showing expanded Gemini account configuration in both unconfigured and configured states).
- **When** rendered across `DisplayScaleMetrics` presets (compact `1024×768`, baseline `1440×900`, 16" MBP `1728×1117`, 27" monitor `1920×1080` HiDPI) and all three themes (`tech`, `anime`, `system`).
- **Then** all text, buttons, text fields, icons, paddings, and corner radii scale via `@Environment(\.displayScaleMetrics)` with no clipping, overflow, or unreadable contrast.
