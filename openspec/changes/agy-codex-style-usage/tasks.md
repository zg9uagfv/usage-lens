# Tasks: agy-codex-style-usage

## 1. AGY Probe Implementation (`probes/agy.py`)
- [x] Create `probes/agy.py` (executable, Python 3.9+ stdlib-only) implementing the `usage-lens/probe@1` contract for `provider: "agy"`.
- [x] Implement read-only credential resolution: `AGY_ACCESS_TOKEN` env override → `AGY_DISABLE_LOCAL_AUTH=1` gate → optional `AGY_AUTH_FILE` / `$HOME/.gemini/antigravity-cli/auth.json` → macOS Keychain (`security find-generic-password -s gemini -a antigravity -w`, 2s timeout, automatically skipped when `HOME` is isolated) with `go-keyring-base64:` decoding.
- [x] Implement strict network security: `_RejectRedirect`, `is_official_url` (`https://daily-cloudcode-pa.googleapis.com`, port 443), `is_official_oauth_url` (`https://oauth2.googleapis.com`, port 443), `3.0s` timeout, `1 MB` response cap, and comprehensive `redact(...)` across stdout/stderr/warnings/errors.
- [x] Implement in-memory OAuth refresh (proactive when within 60s of expiry + single reactive retry on HTTP 401 when `refresh_token` and `client_id` are present; zero disk or Keychain writes).
- [x] Implement live quota queries (`v1internal:loadCodeAssist` with `ideType: "IDE_UNSPECIFIED"`, `v1internal:retrieveUserQuotaSummary`, and `v1internal:retrieveUserQuota`) and conservative max aggregation into normalized `5h` (`5 小时`) and `7d` (`7 天`) windows, plus `account.label` (`id_token_email`) and `account.plan` (`paidTier` / `currentTier`).
- [x] Implement bounded reverse-tail local `today_tokens` aggregation from `~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl` and `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl` (max 50 files, 4 MB/file tail cap, today-only `input_tokens + output_tokens + cache_read_tokens`).
- [x] Implement honest offline/unauthenticated/failure fallback semantics (zero network when unauthenticated; preserve local `today_tokens` with warning on live failure; never fabricate `0%`; strict `allow_nan=False`).

## 2. Swift Core Library & UI Integration
- [x] Update `app/Sources/UsageLensKit/Provider.swift` to add `ProviderCatalog.agy` (`id: "agy"`, `displayName: "AGY"`, `probeRelativePath: "probes/agy.py"`) and include it in `available` and `defaultActiveIDs` right after `codex`.
- [x] Update `app/Sources/UsageLensKit/ProbeRunner.swift` to add `ProviderCatalog.agy.id: 15` to `defaultProviderTimeouts` and strip `AGY_*` environment variables when executing non-`agy` probes.
- [x] Verify `app/Sources/UsageLensUI/PanelView.swift` and `app/Sources/UsageLensUI/SettingsPanelView.swift` render `AGY` cleanly alongside `Codex` (tab bar, account/plan header, `5 小时`/`7 天` rows, `今日 tokens` tile, toggleable settings row) across all 4 `DisplayScaleMetrics` presets and 3 themes, adjusting spacing/truncation if needed.

## 3. Deterministic Automated Tests
- [x] Add `tests/test_agy.py` covering: isolated zero-network `HOME`, `AGY_DISABLE_LOCAL_AUTH=1`, `go-keyring-base64:` decoding + live 200 conservative aggregation (`5h` + `7d` + plan + email), local `today_tokens` aggregation + truncation warning, proactive & reactive 401 in-memory OAuth refresh (zero writes), expired auth fallback with/without local `today_tokens`, partial endpoint failure & malformed/out-of-range values, host pinning, HTTP 302 redirect rejection (`LocalPostServer`), `>1 MB` cap, and secret redaction.
- [x] Update `app/Tests/UsageLensKitTests/KitTests.swift` (or add `AgyProviderTests.swift`) to verify `ProviderCatalog.agy`, `defaultActiveIDs`, `ProbeRunner.effectiveTimeout(for: .agy)`, and env isolation.
- [x] Update `app/Tests/UsageLensUITests/PanelRenderTests.swift` to render `PanelView` with `AGY` selected (windows + plan badge + `today_tokens`) and `SettingsPanelView` with `AGY` active across `DisplayScaleMetrics` presets and themes.

## 4. Verification Commands
Run all of the following locally and confirm 100% pass:
```sh
python3 -m unittest discover -s tests -p "test_*.py" -v
swift test --package-path app
```
