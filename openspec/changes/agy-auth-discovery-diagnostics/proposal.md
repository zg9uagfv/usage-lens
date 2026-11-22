# Proposal: Explainable AGY Authentication Discovery

## Problem Statement

UsageLens now has a dedicated `AGY` provider (`probes/agy.py`), distinct from the `Gemini` provider.  Its current credential resolver is deliberately narrow and reads only:

1. an explicit `AGY_ACCESS_TOKEN` environment override;
2. `$AGY_AUTH_FILE` or `~/.gemini/antigravity-cli/auth.json`; then
3. the macOS login Keychain item with service `gemini` and account `antigravity`.

The user's installed `agy` CLI has an active `~/.gemini/antigravity-cli/` workspace, but this machine has no `auth.json` at the expected location.  A safe boolean-only probe also returned no AGY account label, no server quota windows, no error, and one warning; the Keychain lookup could not establish whether the item was absent or access was denied.  The probe currently collapses all of those conditions to the same unauthenticated guidance, so a signed-in AGY user cannot distinguish:

- looking at the Gemini tab instead of the dedicated AGY tab;
- a missing/changed AGY credential location;
- a locked, denied, or otherwise unavailable login Keychain;
- an expired AGY credential; or
- a sandboxed/development invocation that cannot access the real login Keychain.

The existing `agy-codex-style-usage` change delivered the basic AGY provider and is complete.  This change is limited to making its credential discovery diagnosable and resilient to supported AGY storage variants without broad credential harvesting.

## User Requirement

> I use AGY. UsageLens should reliably detect the AGY account when possible, and clearly tell me what to do when it cannot.

## Goals

1. Keep AGY distinct from Gemini CLI in UI language, setup guidance, and diagnostics.
2. Preserve the current strict, ordered discovery sources, while adding explicit non-secret result codes for each attempted supported source.
3. Detect and report the difference between missing local auth, unavailable/denied Keychain access, malformed local auth, and expired/unrefreshable credentials.
4. Add only documented/narrow AGY locations or Keychain identifiers confirmed by a versioned fixture or public AGY release material.  Do not scan the whole Keychain, browser profiles, or arbitrary files for tokens.
5. Keep all credential contents out of JSON, stdout, stderr, app state, analytics, and test fixtures.

## Non-Goals

- Reading or copying Chrome/Google browser cookies or password databases.
- Searching all Keychain items, guessing service/account names, or recording their labels.
- Altering AGY's login state, refreshing credentials on disk/Keychain, or embedding an OAuth login flow in UsageLens.
- Treating Gemini CLI (`~/.gemini/oauth_creds.json`) credentials as AGY credentials; the two providers use different quota hosts and must remain separate.

## Decision Required

Before implementation, validate the AGY version's actual credential source outside a development sandbox using a fixture generated from the user's own installation with secrets removed.  If AGY has moved its Keychain item, add only that verified service/account pair to a small, documented allowlist; otherwise ship diagnostics and re-login guidance rather than widening access.

## Research amendment — 2026-11-22

The decision is to keep the existing exact Keychain tuple and implement the remaining isolation and verification work before acceptance. The fixture is prior evidence, not a fresh credential inspection or proof of packaged-app access. Official current docs describe an “Antigravity CLI” item in Keychain Access; this display label does not establish a different service/account tuple. No broader lookup is justified.

Include a narrowly scoped Gemini OAuth compatibility fix: accept an explicit Google Cloud project using the precedence and request semantics in design.md. Google documents project configuration for Workspace/Code Assist Google sign-in; merely inheriting the variable does not implement support. Keep API-key/Vertex/ADC authentication outside these OAuth quota probes. AGY's own alternate auth modes are not interchangeable with its saved Google OAuth profile.

Acceptance remains blocked by the existing REJECT report: full Swift test evidence, inherited-environment isolation, real packaged login/logout/re-login results, and coordinator-owned relay/reviewer workflow resolution are outstanding. Research does not change relay state, approve implementation, or close those gates. See design.md for source attribution, limitations, and a safe manual procedure; tasks.md supersedes earlier unchecked/checked claims with evidence-based status.

## User-directed amendment — AGY Keychain Refresh Write-Back (2026-11-22)

By explicit user request, the native Swift 5.9+ macOS implementation (`app/Sources/UsageLensKit/AgyNativeProbe.swift`) now supersedes the earlier zero-Keychain-write non-goal **solely** for atomic in-place write-back of refreshed OAuth credentials to the exact Keychain generic-password item `(service: "gemini", account: "antigravity")` after a verified refresh via pinned `https://oauth2.googleapis.com/token`.

All other non-goals and security invariants remain strictly enforced:
- Exact tuple `(service: "gemini", account: "antigravity")` only; no Keychain enumeration, no `SecItemAdd`/`SecItemDelete`, no ACL widening.
- Zero writes to local auth files (`$AGY_AUTH_FILE`, `~/.gemini/antigravity-cli/auth.json`) and zero Keychain access under isolated `HOME`.
- Fail-closed refresh response expiry verification, lossless preservation of unknown payload fields, round-trip pre-write verification, and zero raw token output or secret logging.

