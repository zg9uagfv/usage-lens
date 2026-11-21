# Behavioral Specification: Real-Time Codex Server Usage & Automatic Gemini Local Auth Reuse

## Requirement 1: Codex Live Server Usage Query (Live-First)

When valid local Codex authentication is present (`~/.codex/auth.json` with a non-empty `tokens.access_token`, or explicit `CODEX_ACCESS_TOKEN` override), `probes/codex.py` queries the official live usage endpoint before falling back to local session logs.

### Scenario 1.1: Live server query succeeds with 5h and 7d windows
- **Given** `~/.codex/auth.json` exists with a non-empty `tokens.access_token` (and optional `tokens.account_id` and `tokens.id_token` containing an `email` claim) and `GET https://chatgpt.com/backend-api/wham/usage` returns HTTP `200` with `plan_type` and `rate_limit.primary_window` + `rate_limit.secondary_window`.
- **When** `probes/codex.py` runs (with no args or `--json`).
- **Then** the probe sends `GET https://chatgpt.com/backend-api/wham/usage` with:
  - `Authorization: Bearer <access_token>`
  - `Accept: application/json`
  - `ChatGPT-Account-Id: <account_id>` (when `account_id` is available)
- **And** exits with code `0`, emitting a single strict JSON line (`usage-lens/probe@1`) with:
  - `provider == "codex"`
  - `account == {"label": "<email or null>", "plan": "<plan_type or claim plan or null>"}`
  - `observed_at == generated_at`
  - `stale == false`
  - `windows` containing canonical `5h` (`"5 小时"`, `window_seconds` from `limit_window_seconds` or `18000`, `basis: "server"`) and `7d` (`"7 天"`, `window_seconds` from `limit_window_seconds` or `604800`, `basis: "server"`), with `used_percent`, `resets_at` (UTC ISO8601), and `expired` accurately computed
  - `usage` still populated from local `~/.codex/sessions/` `today_tokens` (`{"today_tokens": <int>, "source": "local"}` or `null` if no today records)
  - `error == null`
  - `warnings` empty (unless a numeric/window anomaly or truncated local `today_tokens` scan occurred).

### Scenario 1.2: Live server response contains invalid, out-of-range, or NaN values
- **Given** `GET https://chatgpt.com/backend-api/wham/usage` returns `used_percent` outside `0..100` (e.g., `-5`, `150`, `NaN`, or boolean) or a past `reset_at`.
- **When** `probes/codex.py` normalizes the response.
- **Then**:
  - Out-of-range or non-finite `used_percent` becomes `null` + a Chinese warning, and stdout remains strictly valid JSON (`allow_nan=False`).
  - Past `reset_at` sets `expired: true` + a Chinese reset warning.
  - Missing `primary_window` or `secondary_window` is omitted (never fabricated as `0%`).

---

## Requirement 2: Codex Local-Log Fallback & Offline Compatibility

### Scenario 2.1: No local Codex auth present (offline / isolated test compatibility)
- **Given** `~/.codex/auth.json` does not exist (or has no `access_token`) and `CODEX_ACCESS_TOKEN` is unset/empty.
- **When** `probes/codex.py` runs.
- **Then** the probe makes **zero** outbound network requests.
- **And** seamlessly reads `~/.codex/sessions/**/rollout-*.jsonl` using the existing latest-frame logic, preserving 100% backward compatibility with all existing `tests/test_codex.py` cases (including `warnings == []` on a clean fresh local log).

### Scenario 2.2: Live server query fails with auth expiry, rate limit, server error, timeout, or redirect
- **Given** `~/.codex/auth.json` has a non-empty `tokens.access_token`, and `GET https://chatgpt.com/backend-api/wham/usage` fails with HTTP `401`/`403`, `429`, `5xx`, timeout (`> 3s`), network error, malformed JSON, oversized body (`> 1 MB`), or HTTP `301`/`302`/`303`/`307`/`308` redirect.
- **When** `probes/codex.py` runs.
- **Then**:
  - The probe does NOT crash and does NOT fabricate `0%`.
  - It gracefully falls back to `~/.codex/sessions/**/rollout-*.jsonl` latest frame.
  - It exits `0` with `error: null`, local frame `windows` (with honest `observed_at`, `stale`, `expired`, and `coverage`), local `today_tokens`, and a redacted Chinese warning explaining the live failure and fallback (e.g., `"实时查询 Codex 服务端失败（登录态已过期，HTTP 401），已回退到本地会话日志"`).
  - If local sessions also contain no valid `rate_limits` frame, it exits `0` with `windows: []` and both the live-fallback warning and the local-log warning.

### Scenario 2.3: Codex redirect rejection & host pinning
- **Given** the Codex live endpoint returns HTTP `302` redirecting to a third-party URL.
- **When** `probes/codex.py` sends the live usage request.
- **Then** `_RejectRedirect` refuses to follow the redirect, the redirect target receives **zero** requests (no `Authorization` or `ChatGPT-Account-Id` leak), and the probe falls back to local logs with a redacted Chinese warning mentioning redirect refusal.

---

## Requirement 3: Gemini / AGY Credential Priority & Automatic Local Auth Reuse

`probes/gemini.py` resolves credentials strictly in priority order:
1. Explicit manual Keychain / environment credentials (`GEMINI_ACCESS_TOKEN`)
2. Automatic reuse of local Gemini CLI / AGY OAuth credentials (`~/.gemini/oauth_creds.json` + optional `~/.gemini/google_accounts.json`)
3. Unconfigured zero-network account gate

### Scenario 3.1: Manual Keychain / environment credentials take highest priority
- **Given** `GEMINI_ACCESS_TOKEN` is set (e.g., injected by `ProbeRunner` from `GeminiAccountStore`) AND `~/.gemini/oauth_creds.json` also exists with different credentials.
- **When** `probes/gemini.py` runs.
- **Then** the probe uses ONLY the `GEMINI_ACCESS_TOKEN` (and `GEMINI_ACCOUNT_EMAIL` / `GEMINI_PROJECT_ID`) from the environment and does NOT read or refresh `~/.gemini/oauth_creds.json`.

### Scenario 3.2: Automatic reuse of fresh local `~/.gemini/oauth_creds.json`
- **Given** `GEMINI_ACCESS_TOKEN` is unset/empty, `~/.gemini/oauth_creds.json` exists with a non-empty unexpired `access_token`, and `~/.gemini/google_accounts.json` contains `{"active": "local@gmail.com"}` (or `oauth_creds.json` contains an `id_token` JWT with an `email` claim).
- **When** `probes/gemini.py` runs.
- **Then** the probe uses the local `access_token` to query `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`.
- **And** exits `0` with `account.label == "local@gmail.com"`, `account.plan`, and server `5h` & `7d` windows (`basis: "server"`).
- **And** writes **zero** files to disk (`~/.gemini/oauth_creds.json` is never modified).

### Scenario 3.3: Automatic in-memory OAuth refresh when local `access_token` is expired or returns HTTP 401
- **Given** `GEMINI_ACCESS_TOKEN` is unset/empty, and `~/.gemini/oauth_creds.json` contains a `refresh_token`, OAuth client credentials (`client_id` + optional `client_secret`, or via `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET`), and either:
  - `expiry_date` is already expired (or within 60s of expiry), OR
  - `access_token` is missing, OR
  - the initial `loadCodeAssist` / `retrieveUserQuota` call returns HTTP `401`.
- **When** `probes/gemini.py` runs.
- **Then** the probe sends `POST https://oauth2.googleapis.com/token` (`grant_type=refresh_token`, strictly pinned to `https://oauth2.googleapis.com`, `_RejectRedirect`, `3.0s` timeout, `1 MB` cap).
- **And** on HTTP `200` with a new `access_token`, retries/completes the quota query in-memory and exits `0` with valid `5h` & `7d` windows.
- **And** writes **zero** files to disk (never overwrites `~/.gemini/oauth_creds.json`).

### Scenario 3.4: Local OAuth token expired and refresh unavailable or fails
- **Given** `GEMINI_ACCESS_TOKEN` is unset/empty, local `~/.gemini/oauth_creds.json` has an expired/rejected `access_token`, and either `refresh_token` / `client_id` is absent or `https://oauth2.googleapis.com/token` fails (400/401/network/timeout/redirect).
- **When** `probes/gemini.py` runs.
- **Then** the probe exits non-zero (`1`) and emits strict JSON with `windows: []` and a redacted Chinese `error` explaining that local Gemini credentials are expired/invalid and guiding the user to re-authenticate in Gemini CLI or configure an account manually in Settings.

### Scenario 3.5: Neither manual nor local credentials exist (zero-network gate preserved)
- **Given** `GEMINI_ACCESS_TOKEN` is unset/empty AND `~/.gemini/oauth_creds.json` is missing, unreadable, malformed, or lacks both `access_token` and `refresh_token`.
- **When** `probes/gemini.py` runs.
- **Then** the probe makes **zero** outbound network requests, writes **zero** files, exits `0`, and returns `windows: []`, `account: {"label": null, "plan": null}`, `error: null`, and `warnings: ["请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"]`.

---

## Requirement 4: Settings UI & UsageLensKit Credential Source Visibility

### Scenario 4.1: Local Gemini auth status detection (read-only, no secret exposure)
- **Given** `GeminiAccountStore` / `GeminiLocalAuthDetector` inspects the user's Keychain and `~/.gemini/` directory.
- **When** determining `GeminiCredentialSource`:
  - If a manual Keychain account is saved → `.manualKeychain(email: "<saved email>")`.
  - Else if `~/.gemini/oauth_creds.json` contains a usable `access_token` or `refresh_token` → `.localCLI(email: "<optional email from google_accounts.json or id_token>")`.
  - Else → `.unconfigured`.
- **Then** no raw `access_token`, `refresh_token`, or `id_token` string is ever returned by the detector or stored in SwiftUI `@State`.

### Scenario 4.2: SettingsPanelView reflects active Gemini credential source
- **Given** the user opens `SettingsPanelView` and expands the `Gemini` row under `"模型厂商"`.
- **When** Gemini is in each of the three states:
  1. **Manual Keychain (`.manualKeychain`)**: Row icon is green (`person.crop.circle.badge.checkmark`); expanded view shows status `"已手动配置账号"`, read-only saved email, masked token `"****************"`, and destructive `"删除"` button. Clicking `"删除"` removes Keychain item, updates source to `.localCLI` (if local file exists) or `.unconfigured`, and calls `onCredentialChange(ProviderCatalog.gemini)` → `store.credentialsDidChange(for: .gemini)`.
  2. **Local CLI Reuse (`.localCLI`)**: Row icon is green (`person.crop.circle.badge.checkmark`); expanded view shows status `"自动复用本机登录态"` (and detected email if available), explains that local `~/.gemini/oauth_creds.json` is being reused read-only, and still provides the manual email/token/projectID form (`"验证并保存"`) for users who wish to override with a manual Keychain account.
  3. **Unconfigured (`.unconfigured`)**: Row icon is secondary (`person.crop.circle`); expanded view shows the manual configuration form and a caption noting that signing in with Gemini CLI (`~/.gemini/oauth_creds.json`) is also automatically reused.
- **And** all three states render cleanly across `DisplayScaleMetrics` (`0.85x–1.60x`) and themes (`tech`, `anime`, `system`).

---

## Requirement 5: Security Redlines & Secret Redaction

### Scenario 5.1: Zero secret leakage across both probes and Swift layer
- **Given** any JWT (`eyJ...`), OpenAI key (`sk-...`), Google access token (`ya29....`), Google refresh token (`1//...`), `Bearer ...`, or opaque 32+ char token appears in an HTTP error, exception message, warning, or stderr output.
- **When** `probes/codex.py`, `probes/gemini.py`, `ProbeRunner`, `SecretRedactor`, or `UsageStore.debugSummaryLine()` processes the text.
- **Then** every token is replaced with `[redacted]` (Python) or `***` (Swift) before reaching stdout, stderr, UI views, or debug logs.

### Scenario 5.2: Read-only probe filesystem guarantee
- **Given** either `probes/codex.py` or `probes/gemini.py` runs under any success, refresh, fallback, or error path.
- **When** comparing `support.fingerprint(home)` before and after execution.
- **Then** zero files are created, modified, or deleted in `HOME`.
