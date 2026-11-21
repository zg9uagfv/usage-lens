# Proposal: Real-Time Codex Server Usage & Automatic Gemini Local Auth Reuse

## Problem Statement

1. **Codex usage is laggy (local-log only)**:
   - `probes/codex.py` currently only scans `~/.codex/sessions/**/rollout-*.jsonl` for the last `event_msg/token_count` frame containing `rate_limits`.
   - If the user has not recently sent a turn in Codex CLI, or after a 5-hour/7-day window resets on the server, clicking **Refresh** in `UsageLens` keeps showing stale/expired local log values that diverge from Codex `/status`.
   - `probes/codex.py` does not reuse the local Codex login session (`~/.codex/auth.json`) to query the live server quota endpoint, and `account.label` is always `null`.

2. **Gemini / AGY requires manual token copy-paste every time**:
   - `probes/gemini.py` currently only accepts credentials via `GEMINI_ACCESS_TOKEN` / `GEMINI_ACCOUNT_EMAIL` environment variables (injected from macOS Keychain via `GeminiAccountStore`).
   - Users who have already signed in with Gemini CLI / AGY on the same machine (`~/.gemini/oauth_creds.json` + `~/.gemini/google_accounts.json`) must still manually extract and paste a short-lived OAuth access token into Settings, and manually replace it whenever it expires (~1 hour).
   - `SettingsPanelView` has no visibility into whether Gemini is currently reusing local CLI credentials or using a manual Keychain override.

## User Requirement

> Codex 改为实时查服务端（复用本机登录态 + 本地日志兜底），并给 AGY / Gemini 加上自动登录/复用本机凭据。

## Current Behavior vs. Desired Behavior

| Aspect | Current Behavior | Desired Behavior |
|---|---|---|
| **Codex refresh with local `~/.codex/auth.json`** | Reads only `~/.codex/sessions/**/rollout-*.jsonl`; stale after idle/reset; `account.label` is `null`. | Queries live `GET https://chatgpt.com/backend-api/wham/usage` using local `~/.codex/auth.json` (`Bearer` token + `ChatGPT-Account-Id`), returning real-time 5h & 7d usage matching Codex `/status`, `account.label` from `id_token` email claim, and local `today_tokens` from `~/.codex/sessions/`. |
| **Codex without auth or on server/network failure** | N/A (always local logs). | When `~/.codex/auth.json` is absent (e.g., isolated tests or unauthenticated machine), makes **zero** network calls and uses local logs silently. When auth exists but live query fails (401/403/429/5xx/timeout/redirect/network), gracefully falls back to local `rollout-*.jsonl` latest frame with an honest Chinese warning explaining the fallback reason. |
| **Gemini with local `~/.gemini/oauth_creds.json` and no Keychain override** | Blocked by account gate (`windows: []` + `"请先在配置中提供 Gemini 账号"`). | Automatically discovers and reuses local `~/.gemini/oauth_creds.json` (and `~/.gemini/google_accounts.json` / `id_token` email) in read-only mode to fetch live 5h & 7d windows. If the cached local `access_token` is expired or returns HTTP 401 and `refresh_token` + OAuth client credentials are available, performs an in-memory refresh via pinned `https://oauth2.googleapis.com/token` without mutating disk files. |
| **Gemini with manual Keychain account in Settings** | Always uses Keychain credentials. | Manual Keychain account retains **highest priority** over local CLI credentials; deleting the manual Keychain account immediately triggers `credentialsDidChange(for: .gemini)` and cleanly falls back to local CLI credentials (if present) or the unconfigured gate. |
| **Gemini with neither Keychain nor local credentials** | Zero network calls, `windows: []`, Chinese guidance warning, `"前往配置"` button. | Preserved verbatim: zero network calls, exit `0`, `windows: []`, guidance warning, and `"前往配置"` button. |
| **Settings UI (`SettingsPanelView`) for Gemini** | Only distinguishes saved Keychain account vs. unconfigured form. | Clearly displays active credential source: `"已手动配置账号"` (Keychain override) vs. `"自动复用本机登录态"` (local CLI credentials detected, with optional manual override form) vs. unconfigured form. |

## Goals

1. **Codex Live-First + Honest Local Fallback**: Upgrade `probes/codex.py` to query `https://chatgpt.com/backend-api/wham/usage` when local Codex auth is present, while preserving local `today_tokens`, deterministic fallback to `~/.codex/sessions/**/rollout-*.jsonl`, and 100% backward compatibility with existing offline `tests/test_codex.py`.
2. **Gemini Automatic Local Credential Reuse & Safe In-Memory Refresh**: Upgrade `probes/gemini.py` with a strict 3-tier credential priority (manual Keychain/env > local `~/.gemini/oauth_creds.json` with optional in-memory OAuth refresh > zero-network unconfigured gate).
3. **Clear Credential Source Visibility in Settings**: Add a read-only local Gemini auth detector in `UsageLensKit` (never exposing token values) and reflect `"自动复用本机登录态"` vs. `"已手动配置账号"` in `SettingsPanelView` with immediate `credentialsDidChange` refresh on save/delete.
4. **Strict Security & Read-Only Boundaries**: Enforce host/scheme pinning, `_RejectRedirect` (no 3xx following), `3.0s` HTTP timeout, `1 MB` response cap, strict finite/range checks (`allow_nan=False`), zero file writes to external CLI auth files, and comprehensive secret redaction (including JWTs, `ya29.*`, `1//*`, `Bearer *`, `sk-*`).
5. **Deterministic Mocked Test Coverage**: Add unit and integration tests for both Python probes (mocked opener + local loopback redirect servers + isolated `HOME`) and Swift Kit/UI (`GeminiLocalAuthDetector`, `SettingsPanelView` states across `DisplayScaleMetrics` and themes).

## Non-Goals

- **Mutating external CLI auth files**: Neither `probes/codex.py` nor `probes/gemini.py` will write back refreshed tokens to `~/.codex/auth.json` or `~/.gemini/oauth_creds.json`, preventing file corruption or refresh races with Codex CLI / Gemini CLI.
- **Interactive browser OAuth login inside UsageLens**: UsageLens reuses existing local CLI login state or manual Keychain credentials rather than embedding an OAuth browser login flow or shipping hardcoded OAuth client secrets.
- **Fabricating usage numbers**: On any live failure, missing window, out-of-range value, or unconfigured state, probes never invent `0%`.
- **Changing DeepSeek or OpenCode probes**: Existing providers remain unaffected.

## Security & Privacy Considerations

- **Zero secret exposure**: Tokens (`access_token`, `refresh_token`, `id_token`, JWTs, `ya29.*`, `1//*`) are never printed to stdout, stderr, UI views, `USAGE_LENS_DEBUG_SUMMARY`, or logs. Both Python probes and `UsageLensKit.SecretRedactor` redact all credential patterns.
- **Read-only local auth inspection**: Local `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`, and `~/.gemini/google_accounts.json` are opened strictly read-only. In Swift, `GeminiLocalAuthDetector` only inspects presence and non-secret email metadata—it never passes raw local tokens into SwiftUI state.
- **Pinned official endpoints only**:
  - Codex live usage: `https://chatgpt.com/backend-api/wham/usage` (host `chatgpt.com`, port `443`).
  - Gemini quota: `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (host `cloudcode-pa.googleapis.com`, port `443`).
  - Gemini OAuth refresh: `https://oauth2.googleapis.com/token` (host `oauth2.googleapis.com`, port `443`).
- **No redirects**: All HTTP requests use `_RejectRedirect` so `Authorization` headers and refresh tokens can never be forwarded to a 3xx redirect target.
- **Process isolation**: `ProbeRunner` continues to isolate Keychain env vars per provider (`GEMINI_*` only for `gemini`, `DEEPSEEK_API_KEY` only for `deepseek`).
