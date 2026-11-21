# Proposal: Codex-Style First-Class AGY (Antigravity) Usage Display

## Problem Statement

1. **AGY (Antigravity) is not displayed out of the box in UsageLens**:
   - The current `probes/gemini.py` only inspects `~/.gemini/oauth_creds.json` (Gemini CLI's file-based OAuth cache) and queries `https://cloudcode-pa.googleapis.com`.
   - On macOS, **AGY (Antigravity)** does **not** write `~/.gemini/oauth_creds.json`. Instead, AGY stores its OAuth credentials in the macOS login Keychain via `go-keyring` (`service="gemini"`, `account="antigravity"`, payload prefixed with `go-keyring-base64:` encoding a UTF-8 JSON object) and tracks its live quota pool on `https://daily-cloudcode-pa.googleapis.com` (`v1internal:loadCodeAssist`, `v1internal:retrieveUserQuotaSummary`, `v1internal:retrieveUserQuota`).
   - As a result, a user who is signed into AGY sees nothing for AGY in UsageLens and would otherwise be forced to manually extract and paste tokens into Gemini settings — which still queries the wrong host (`cloudcode-pa.googleapis.com`) and misses AGY's real daily/5h pool usage.

2. **No local AGY token usage statistics**:
   - Unlike `probes/codex.py`, which computes local `today_tokens` from `~/.codex/sessions/**/rollout-*.jsonl` and displays the `"今日 tokens"` metric card alongside real-time `5h`/`7d` quota bars, UsageLens currently does not aggregate AGY's local session transcripts (`~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl` and `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`).

## User Requirement

> 按照codex的方式把agy的显示出来

## Current Behavior vs. Desired Behavior

| Aspect | Current Behavior | Desired Behavior |
|---|---|---|
| **Provider presence** | Only `Codex`, `Gemini`, `OpenCode`, `DeepSeek` exist; no dedicated `AGY` tab. | First-class `AGY` provider (`id: "agy"`, `displayName: "AGY"`, `probes/agy.py`), enabled by default right beside `Codex` in `ProviderCatalog.defaultActiveIDs`, toggleable in `SettingsPanelView`. |
| **Auth discovery** | `gemini.py` looks for `~/.gemini/oauth_creds.json` (absent for AGY users) and prompts for manual token entry. | `probes/agy.py` automatically reuses AGY's local login state read-only (macOS Keychain `service="gemini"`, `account="antigravity"` `go-keyring-base64:` payload, or env/file override for tests) with **zero manual token copy-pasting** and **zero disk/keychain writes**. |
| **Live quota windows** | Not queried on AGY's official host. | Queries pinned `https://daily-cloudcode-pa.googleapis.com` (`loadCodeAssist` + `retrieveUserQuotaSummary` + `retrieveUserQuota`), normalizing live `5h` (`5 小时`) and `7d` (`7 天`) windows via conservative max aggregation, plus `account.label` (`id_token_email`) and `account.plan` (`paidTier` / `currentTier`). |
| **Local `today_tokens`** | Not computed for AGY. | Scans local AGY transcript logs (`~/.gemini/antigravity-cli/brain/` and `~/.gemini/antigravity/brain/`) read-only with bounded tail-scanning to report `usage: {"today_tokens": N, "source": "local"}` — matching Codex's `"今日 tokens"` card. |
| **Offline / unauthenticated / error fallback** | N/A | Isolated/unauthenticated environments make **zero** network calls and return exit `0` with `windows: []` and clear Chinese guidance. When live queries fail while local `today_tokens` exists, preserves local `today_tokens` with a redacted Chinese fallback warning; otherwise surfaces a clean redacted error without fabricating `0%`. |

## Goals

1. **Dedicated First-Class `AGY` Provider**: Add `ProviderCatalog.agy` (`id: "agy"`, `displayName: "AGY"`, `probeRelativePath: "probes/agy.py"`, `requiresAPIKey: false`, `requiresAccount: false`) enabled by default alongside `Codex`, while keeping `probes/gemini.py` focused on Gemini CLI / manual Gemini accounts.
2. **Codex-Style Zero-Config Probe (`probes/agy.py`)**:
   - Read-only automatic discovery of AGY's macOS Keychain `go-keyring` OAuth token (`service="gemini"`, `account="antigravity"`).
   - Live server quota retrieval from pinned `https://daily-cloudcode-pa.googleapis.com` (`v1internal:loadCodeAssist`, `v1internal:retrieveUserQuotaSummary`, `v1internal:retrieveUserQuota`) with conservative aggregation into standard `5h` and `7d` `usage-lens/probe@1` windows.
   - Optional in-memory OAuth token refresh via pinned `https://oauth2.googleapis.com/token` when expired/401 and refresh client credentials are available (zero writes to Keychain or disk).
   - Bounded read-only local `today_tokens` aggregation from AGY transcript logs.
3. **Clean `ProbeRunner` & UI Integration**:
   - Configure bounded per-provider timeout (`15s`) and strict environment variable isolation for `agy` in `ProbeRunner`.
   - Ensure `PanelView` (tab, header email + plan badge, `5 小时`/`7 天` progress rows, `"今日 tokens"` tile, warnings/stale/empty states) and `SettingsPanelView` (toggleable `AGY` provider row) render cleanly across all 4 `DisplayScaleMetrics` profiles and 3 themes.
4. **Strict Security & Privacy Boundaries**:
   - Pinned HTTPS hosts (`daily-cloudcode-pa.googleapis.com`, `oauth2.googleapis.com`, port `443`), `_RejectRedirect` (no 3xx following), `3.0s` per-request timeout, `1 MB` response cap, strict finite JSON (`allow_nan=False`), zero writes to AGY files/Keychain, and full secret redaction across stdout, stderr, warnings, and errors.
5. **Deterministic Mocked Test Coverage**:
   - Comprehensive Python unit/integration tests (`tests/test_agy.py`) using mocked openers, local loopback redirect servers, and isolated `HOME` (zero real Keychain or internet access).
   - Swift `UsageLensKitTests` and `UsageLensUITests` verifying `ProviderCatalog.agy`, `ProbeRunner` timeout/env isolation, and hosted AppKit/SwiftUI rendering of the AGY panel across themes and display scales.

## Non-Goals

- **Mutating AGY's Keychain item or local files**: `probes/agy.py` is strictly read-only; it never writes refreshed tokens back to macOS Keychain or `~/.gemini/`.
- **Interactive OAuth login UI inside UsageLens**: Users sign in via `agy` / Antigravity directly; UsageLens reuses that login state automatically.
- **Shipping hardcoded OAuth client secrets**: In-memory refresh uses only credentials explicitly present in the payload or environment (`AGY_OAUTH_CLIENT_ID` / `AGY_OAUTH_CLIENT_SECRET`); otherwise expired tokens produce an honest Chinese prompt to re-authenticate in `agy`.
- **Altering `probes/codex.py`, `probes/gemini.py`, `probes/deepseek.py`, or `probes/opencode.py` behavior**: Existing providers remain intact and regression-free.

## Security & Privacy Considerations

- **Zero secret exposure**: OAuth access tokens (`ya29.*`), refresh tokens (`1//*`), JWTs (`eyJ...`), `Bearer` headers, `sk-*`, and opaque `>=32`-char tokens are never printed to stdout, stderr, UI, or logs; both `probes/agy.py` and `UsageLensKit.SecretRedactor` enforce defense-in-depth redaction.
- **No Keychain ACL popups in Swift**: Keychain reading is performed exclusively read-only inside `probes/agy.py` via `/usr/bin/security find-generic-password -s gemini -a antigravity -w` (with a 2-second timeout and automatic bypass when `HOME` is isolated or `AGY_DISABLE_LOCAL_AUTH=1`), avoiding ad-hoc Swift binary Keychain prompts.
- **Strict network pinning & no redirects**: Every HTTPS call validates scheme `https`, exact pinned host, port `443`, uses `_RejectRedirect`, enforces `3.0s` timeout and `1 MB` body limit.
- **Process env isolation**: `ProbeRunner` strips `AGY_*` variables from all non-`agy` probes and strips `DEEPSEEK_API_KEY` / `GEMINI_*` from `agy`.
