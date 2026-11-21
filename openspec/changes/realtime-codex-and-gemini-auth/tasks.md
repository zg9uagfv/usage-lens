# Implementation Tasks: realtime-codex-and-gemini-auth

## 1. Codex Live Server Usage & Local Fallback (`probes/codex.py`)
- [x] Add read-only local auth reader `_load_codex_auth()` in `probes/codex.py`:
  - Support explicit env overrides (`CODEX_ACCESS_TOKEN`, `CODEX_ACCOUNT_ID`, `CODEX_ACCOUNT_EMAIL`) for testing/dev.
  - Read `~/.codex/auth.json` (from `Path.home() / ".codex" / "auth.json"`) read-only when env override is unset; extract `tokens.access_token`, `tokens.account_id`, and non-secret `email` / `chatgpt_plan_type` / `chatgpt_account_id` claims from `tokens.id_token` JWT payload.
  - Return `None` cleanly when `~/.codex/auth.json` is absent or lacks `access_token` (ensuring zero network calls in offline/isolated-`HOME` tests).
- [x] Add pinned HTTPS client in `probes/codex.py`:
  - Implement `_RejectRedirect(urllib.request.HTTPRedirectHandler)` refusing all 3xx redirects and module-level `_OPENER`.
  - Implement `is_official_url(url)` strictly pinned to `https://chatgpt.com` (port `None` or `443`).
  - Query `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <access_token>`, `Accept: application/json`, and optional `ChatGPT-Account-Id: <account_id>`, enforcing `3.0s` timeout and `1 MB` response cap.
  - Implement `redact(text)` stripping JWTs (`eyJ...`), `Bearer ...`, `sk-...`, `key/token/secret/password=...`, and 32+ char opaque tokens on all warnings, errors, and stderr logs.
- [x] Parse live `wham/usage` response into canonical `5h` (`primary_window`) and `7d` (`secondary_window`) windows:
  - Map `used_percent` via `_clean_percent`, `limit_window_seconds` (fallback `18000` / `604800`), `reset_at` (fallback `now + reset_after_seconds`), `expired`, `basis: "server"`, `observed_at = generated_at`, `stale = False`, `account = {"label": email, "plan": plan}`.
  - Always compute and attach local `today_tokens` from `~/.codex/sessions/` via `find_today_tokens`.
- [x] Implement graceful local-log fallback in `build_payload()`:
  - When live query is attempted and fails (401/403/429/5xx/timeout/network/redirect/malformed/empty windows), fall back to `find_latest_frame(SESSIONS_DIR)` and append a redacted Chinese warning explaining the fallback reason.
  - Preserve `account.label` from `id_token` email claim when falling back, and never fabricate `0%` or write any files.

## 2. Gemini Local Credential Reuse & In-Memory Refresh (`probes/gemini.py`)
- [x] Add read-only local credential discovery `_load_local_credentials()` in `probes/gemini.py`:
  - Enforce 3-tier priority: (1) `GEMINI_ACCESS_TOKEN` env var (manual Keychain), (2) `~/.gemini/oauth_creds.json` + optional `~/.gemini/google_accounts.json` / `id_token` JWT `email` claim (skipped if `GEMINI_DISABLE_LOCAL_AUTH=1`), (3) unconfigured zero-network gate.
  - Parse `access_token`, `refresh_token`, `expiry_date` (ms or s), `client_id` / `client_secret` (file or `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET`), and non-secret `email`.
- [x] Add safe in-memory OAuth token refresh `_refresh_access_token()`:
  - Pin strictly to `https://oauth2.googleapis.com/token` (`is_official_oauth_url`, `_RejectRedirect`, `3.0s` timeout, `1 MB` cap).
  - Trigger only for local credentials when `access_token` is missing/expired (within 60s skew) or on a single HTTP `401` retry.
  - Keep refreshed `access_token` strictly in memory (**zero disk writes** to `~/.gemini/oauth_creds.json`).
  - Return clear redacted Chinese error messages when local credentials expire and cannot be refreshed.
- [x] Extend `redact(text)` in `probes/gemini.py` to also strip JWTs (`eyJ...`) in addition to `ya29.*`, `1//*`, `Bearer *`, `sk-*`, and 32+ char tokens.

## 3. Core Library & Settings UI (`app/Sources/UsageLensKit/` & `app/Sources/UsageLensUI/`)
- [x] Update `app/Sources/UsageLensKit/GeminiAccountStore.swift`:
  - Add `GeminiCredentialSource` (`.manualKeychain(email:)`, `.localCLI(email:)`, `.unconfigured`) and `GeminiLocalAuthInfo`.
  - Add read-only `detectLocalCLIAuth(homeDirectory:)` and `credentialSource(storage:homeDirectory:)` that inspect `~/.gemini/oauth_creds.json` and `~/.gemini/google_accounts.json` (plus `id_token` email claim) without ever returning or storing token plaintext.
  - Pass `GEMINI_DISABLE_LOCAL_AUTH=1` in `validationMessage(...)` `environmentOverrides` so manual account validation tests only the candidate token.
- [x] Update `app/Sources/UsageLensKit/SecretRedactor.swift`:
  - Add JWT redaction pattern (`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+` → `***`).
- [x] Update `app/Sources/UsageLensUI/SettingsPanelView.swift`:
  - Support `GeminiCredentialSource` (with optional test-injection parameter on `init`, preserving backward compatibility).
  - Display `"自动复用本机登录态"` (with optional detected email) when local CLI auth is active, alongside the manual override form (`"验证并保存"`).
  - Display `"已手动配置账号"` when a manual Keychain account is saved; deleting it re-evaluates `credentialSource()` and triggers `onCredentialChange(ProviderCatalog.gemini)` → `store.credentialsDidChange(for: .gemini)`.
  - Render green `person.crop.circle.badge.checkmark` for both `.manualKeychain` and `.localCLI`, and secondary `person.crop.circle` for `.unconfigured`.

## 4. Automated Tests (`tests/` & `app/Tests/`)
- [x] Update `tests/test_codex.py`:
  - Keep all existing offline tests passing untouched.
  - Add mocked live server tests: 200 success (`5h`+`7d` + `account.label` + `plan` + local `today_tokens`), invalid/NaN/expired live values, HTTP 401/403/429/500/timeout/malformed/oversized fallback to local logs with Chinese warning, fallback with empty logs, `LocalServer` 302 redirect rejection (no `Authorization` / `ChatGPT-Account-Id` leak), `is_official_url` unit tests, secret redaction, and read-only FS fingerprint check.
- [x] Update `tests/test_gemini.py`:
  - Keep all existing tests passing untouched.
  - Add local credential reuse tests: manual env priority over local file, fresh `~/.gemini/oauth_creds.json` + `google_accounts.json` reuse, `id_token` email fallback, proactive in-memory refresh on expired `expiry_date`, reactive in-memory refresh on HTTP 401, refresh `LocalPostServer` 302 redirect rejection, expired local token without refresh credentials / failed refresh error, `GEMINI_DISABLE_LOCAL_AUTH=1`, and read-only FS fingerprint check.
- [x] Update `app/Tests/UsageLensKitTests/` and `app/Tests/UsageLensUITests/`:
  - Add unit tests for `GeminiAccountStore.detectLocalCLIAuth`, `GeminiAccountStore.credentialSource`, `SecretRedactor` JWT redaction, and `SettingsPanelView` offscreen rendering in `.localCLI`, `.manualKeychain`, and `.unconfigured` states across `DisplayScaleMetrics` presets.

## 5. Local Verification Commands
- [x] Run Python probe test suite:
  ```bash
  python3 -m unittest discover -s tests -v
  ```
- [x] Run isolated smoke checks (zero network when `HOME` is empty):
  ```bash
  HOME="$(mktemp -d)" python3 probes/codex.py | python3 -m json.tool
  HOME="$(mktemp -d)" python3 probes/gemini.py | python3 -m json.tool
  ```
- [x] Run Swift build and test suite:
  ```bash
  cd app && swift build && swift test
  ```
- [x] Verify `git status` and `git diff` contain only intended changes and zero real secrets/tokens/emails.
