# Packaged Authentication Lifecycle & Owner Acceptance Evidence (`agy-auth-discovery-diagnostics`)

- **Recorded Timestamp**: 2026-11-22 19:10:15 +0800
- **HEAD Commit**: `11bc5649672a271e989f37818f55d7ebc7c113e4`
- **Frozen Swift Tree SHA-256** (31 non-`.build` `app/**/*.swift` files): `6d2f14251bab3c2d4f41527ed042dc288680772cedbca87e5ba312ccba0539f5`
- **Dirty Python Reference Digest** (4 files: `probes/agy.py`, `probes/gemini.py`, `tests/test_agy.py`, `tests/test_gemini.py`): `b1680c8aa532a9aa2b7654aeb2dc16872b5e3bddcd36cfc3b8976cb0000aeca7`
- **Packaged Bundle Path**: `app/dist/UsageLens.app`
- **Bundle Identifier**: `dev.usage-lens.UsageLens`
- **Architecture & Signing**: `Mach-O thin (arm64)`, `Signature=adhoc`, `Sealed Resources version=2 rules=13 files=4`, `TeamIdentifier=not set` (local ad-hoc bundle built `2026-11-22 14:48 +0800`, after latest Swift modification `14:40 +0800`)
- **Executable SHA-256** (`app/dist/UsageLens.app/Contents/MacOS/UsageLens`): `b5d6ad75e8e916d5d8f4ae761e177c6b3176629fb5fb8f0d8e594758538add9e`
- **Bundled Resource Probe Parity** (`app/dist/UsageLens.app/Contents/Resources/probes/*.py` == workspace `probes/*.py`):
  - `agy.py`: `6b56f4b26c41489b4693b4b9617e0d326add730016e8e086cce0e42d88c7aa80` (exact match)
  - `codex.py`: `4aba49ab2e750f2a0a3373f51ddd4a1765e05e945fccda22c1c0f361f985351f` (exact match)
  - `deepseek.py`: `89ac023ce9eb783cfab45f43c2f44084fe3b91607b6c3a97aef92b2e548f53a4` (exact match)
  - `gemini.py`: `7e22f3eb5322ece771cdaf0267693760d21fdf973a01ec19439fb6c6938f02a9` (exact match)
- **Host Environment**: `macOS 27.0.1 (Build 26A434)` | `agy --version`: `1.5.14`
- **Override Env Vars (boolean presence only)**:
  - `AGY_ACCESS_TOKEN`: `absent`
  - `AGY_AUTH_FILE`: `absent`
  - `AGY_DISABLE_LOCAL_AUTH`: `absent`
  - `GEMINI_ACCESS_TOKEN`: `absent`
  - `GEMINI_DISABLE_LOCAL_AUTH`: `absent`

## Reduced Lifecycle Acceptance Table

No credentials, emails, tokens, project IDs, auth URLs, raw logs, or real-account screenshots were collected or stored.

| stage | provider | result | account_present | window_count | warning_category | elapsed_seconds | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `login` | `agy` | `pass` (owner-confirmed) | `true` | `owner-observed-nonempty` | `none` | `not-timed` | Owner launched `app/dist/UsageLens.app`, switched from Gemini tab to dedicated AGY tab, and confirmed live AGY display (`"看到了"`). No Keychain ACL mutation or manual token entry. |
| `logout` | `agy` | `waived-by-owner` | `n/a` | `n/a` | `n/a` | `n/a` | Explicitly waived by owner on 2026-11-22 19:10:15 +0800 (`decisions.tsv:11`); covered synthetically in `swift-test-evidence.md` and `python-test-evidence.md`. |
| `re-login` | `agy` | `waived-by-owner` | `n/a` | `n/a` | `n/a` | `n/a` | Explicitly waived by owner on 2026-11-22 19:10:15 +0800 (`decisions.tsv:11`). |
| `relaunch` | `agy` | `waived-by-owner` | `n/a` | `n/a` | `n/a` | `n/a` | Explicitly waived by owner on 2026-11-22 19:10:15 +0800 (`decisions.tsv:11`). |
| `workspace-project` | `gemini` | `synthetic-only / waived-by-owner` | `n/a` | `n/a` | `n/a` | `n/a` | No real Google Workspace live success is claimed; Gemini project-context routing is verified synthetically (`GeminiAccountTests` + `test_gemini.py`, 0 failures) and real Workspace acceptance is explicitly waived by owner (`decisions.tsv:11`). |

## Explicit Owner Waiver & Scope Boundary

- On 2026-11-22 19:10:15 +0800, after confirming packaged `UsageLens.app` AGY live display (`login`), the repository owner explicitly approved waiving the remaining interactive `logout`, `re-login`, `relaunch`, manual visual-legibility checklist, and real Gemini Workspace verification steps, accepting the delivery on the basis of:
  1. Packaged `UsageLens.app` live AGY confirmation;
  2. Complete native Swift test evidence (`123/123` passed, `0` warnings, `swift-test-evidence.md`);
  3. Complete isolated Python reference test evidence (`101/101` passed, `python-test-evidence.md`);
  4. Final independent read-only Codex review (`VERDICT: PASS`) under the owner-approved `thermos` substitution exception (`decisions.tsv:7`).
- Limitations remain explicitly documented rather than overstated: signed-bundle Keychain write-back under expired live credentials, live `/logout` upstream token revocation behavior, cold relaunch persistence, and real Workspace Gemini project routing were not exercised end-to-end in the live session and rely on synthetic coverage plus the owner waiver recorded in `.orca-relay/decisions.tsv`.
