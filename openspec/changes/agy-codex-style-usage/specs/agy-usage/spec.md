# Spec: AGY (Antigravity) Codex-Style Usage

## Capability: `agy-usage`

Provides first-class, zero-configuration AGY (Antigravity) quota window and local token usage monitoring in UsageLens, matching the Codex provider's UX, data contract (`usage-lens/probe@1`), and security guarantees.

---

### Scenario 1: Automatic Local AGY Auth Discovery & Live Server Quota Windows
- **Given** the user is signed into AGY on macOS (macOS Keychain contains generic password `service="gemini"`, `account="antigravity"` with a `go-keyring-base64:`-encoded JSON payload containing `token.access_token`, `token.expiry`, and `id_token_email`)
- **And** `https://daily-cloudcode-pa.googleapis.com` returns valid responses for `v1internal:loadCodeAssist` (`cloudaicompanionProject`, `paidTier`/`currentTier`), `v1internal:retrieveUserQuotaSummary` (`groups[*].buckets[*]`), and `v1internal:retrieveUserQuota` (`buckets[*]`)
- **When** `probes/agy.py` executes
- **Then** it reads the local AGY credential read-only without modifying the Keychain or any files on disk
- **And** emits a single strict `usage-lens/probe@1` JSON object to stdout with exit code `0`
- **And** `provider` is `"agy"`, `stale` is `false`, `observed_at == generated_at`, `error` is `null`
- **And** `account.label` is populated from `id_token_email` and `account.plan` is populated from `paidTier.name` (falling back to `paidTier.id`, `currentTier.name`, or `currentTier.id`)
- **And** `windows` contains normalized `5h` (`"5 小时"`, `window_seconds: 18000`, `basis: "server"`) and `7d` (`"7 天"`, `window_seconds: 604800`, `basis: "server"`) entries computed by conservative max aggregation (`used_percent = round((1 - remainingFraction) * 100, 2)`, tie-breaking on earliest `resetTime`) across both `retrieveUserQuotaSummary` and `retrieveUserQuota`.

### Scenario 2: Local AGY `today_tokens` Aggregation
- **Given** local AGY transcript logs exist under `~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl` and/or `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl` containing `PLANNER_RESPONSE` entries dated today with `input_tokens`, `output_tokens`, and `cache_read_tokens`
- **When** `probes/agy.py` executes
- **Then** it scans up to the 50 most recently modified transcript files (bounded to the trailing `4 MB` per file, stopping once file mtime is earlier than today)
- **And** sums finite non-negative `input_tokens + output_tokens + cache_read_tokens` for today's entries into `usage: {"today_tokens": <int>, "source": "local"}`
- **And** if no today entries exist, `usage` is `null` (never fabricated as `0`)
- **And** if any today-modified transcript exceeds `4 MB`, appends a Chinese truncation warning.

### Scenario 3: In-Memory OAuth Token Refresh (Zero Disk/Keychain Writes)
- **Given** the local AGY credential's `token.expiry` is within 60 seconds of expiry (or already expired), OR a live quota call returns HTTP `401`
- **And** `token.refresh_token` and an OAuth `client_id` (from payload or `AGY_OAUTH_CLIENT_ID`) are available
- **When** `probes/agy.py` executes
- **Then** it sends a form-encoded `POST https://oauth2.googleapis.com/token` (`grant_type=refresh_token`) using `_RejectRedirect`, `3.0s` timeout, and `1 MB` cap
- **And** retries the quota request at most once (`refreshed_once` guard) with the refreshed `access_token` kept strictly in memory
- **And** writes **zero** changes to macOS Keychain or any local files.

### Scenario 4: Expired/Invalid Local AGY Auth Without Refresh Credentials
- **Given** the local AGY credential is expired or returns HTTP `401`/`403` and cannot be refreshed (no `client_id` or refresh fails)
- **When** `probes/agy.py` executes
- **Then** it never fabricates `0%` window values
- **And** if local `today_tokens` is available, it exits `0` with `windows: []`, `usage: {"today_tokens": N, "source": "local"}`, `error: null`, and a redacted Chinese warning guiding the user to re-run `agy` to refresh login state
- **And** if local `today_tokens` is unavailable, it exits `1` with `windows: []`, `usage: null`, and a redacted Chinese `error` guiding the user to re-run `agy` to refresh login state.

### Scenario 5: Unauthenticated or Isolated `HOME` Environment (Zero-Network Gate)
- **Given** `AGY_ACCESS_TOKEN` is unset AND either `AGY_DISABLE_LOCAL_AUTH=1` OR `HOME` is isolated (differs from the OS user home directory and contains no `$HOME/.gemini/antigravity-cli/auth.json`) OR no AGY Keychain item exists
- **When** `probes/agy.py` executes
- **Then** it makes **zero** network requests and **zero** writes to disk
- **And** exits `0` with `windows: []`, `error: null`, and a clear Chinese guidance warning (`"未检测到本机 AGY 登录态，请先运行 agy 登录以查看 5 小时与 7 天用量"`)
- **And** still includes `usage` if local `today_tokens` exists in the isolated `HOME`.

### Scenario 6: Partial Server Response & Fallback Resilience
- **Given** `loadCodeAssist` succeeds, `retrieveUserQuotaSummary` fails or omits a window (e.g., returns only `7d` or fails with HTTP 500), while `retrieveUserQuota` succeeds (or vice versa)
- **When** `probes/agy.py` executes
- **Then** it normalizes all valid windows from whichever endpoint succeeded, appends a Chinese warning for any missing window (`5h` or `7d`) or partial endpoint failure, and never fabricates `0%`
- **And** any non-finite or out-of-range `remainingFraction` (outside `[0.0, 1.0]`) or `used_percent` (outside `[0.0, 100.0]`) becomes `null` with a Chinese warning; stdout strictly rejects `NaN`/`Infinity` (`allow_nan=False`).

### Scenario 7: Security Redlines (Host Pinning, No Redirects, Size/Time Caps, Redaction)
- **Given** any HTTP response redirects (`301`/`302`/`303`/`307`/`308`), exceeds `1 MB`, times out past `3.0s`, or resolves to a non-pinned host/scheme/port
- **When** `probes/agy.py` performs an HTTP request
- **Then** `_RejectRedirect` blocks redirect following so `Authorization` / `refresh_token` is never sent to any redirect target
- **And** `is_official_url` accepts only `https://daily-cloudcode-pa.googleapis.com` (port `443` / default) and `is_official_oauth_url` accepts only `https://oauth2.googleapis.com` (port `443` / default)
- **And** all stdout `warnings`, `error`, and stderr log lines pass through `redact(...)` stripping Google OAuth access tokens (`ya29.*`), refresh tokens (`1//*`), JWTs (`eyJ...`), `Bearer *`, `sk-*`, key/token/secret assignments, and opaque `>=32`-char strings.

### Scenario 8: First-Class Codex-Style UI & `ProbeRunner` Integration
- **Given** UsageLens launches with default settings
- **When** the user opens the menu bar popover (`PanelView`) and Settings (`SettingsPanelView`)
- **Then** `AGY` appears in `ProviderTabBar` right beside `Codex` (enabled by default in `ProviderCatalog.defaultActiveIDs`)
- **And** selecting `AGY` displays the exact Codex-style layout: account email + plan badge header, `5 小时` and `7 天` progress rows with reset countdown and `"服务端"` basis, `"今日 tokens"` local metric card (when available), and honest warning/stale/empty states
- **And** `ProbeRunner` grants `agy` a bounded `15s` timeout budget and isolates `AGY_*` env vars strictly to `agy` while stripping `DEEPSEEK_API_KEY` and `GEMINI_*`
- **And** `SettingsPanelView` lists `AGY` as a toggleable provider row (removable and re-addable via `"添加模型厂商"` without requiring manual token entry)
- **And** both `PanelView` and `SettingsPanelView` render cleanly without clipping or overflow across all 4 `DisplayScaleMetrics` presets (`compact`, `standard`, `comfortable`, `large`) and all 3 themes (`system`, `light`, `dark`).
