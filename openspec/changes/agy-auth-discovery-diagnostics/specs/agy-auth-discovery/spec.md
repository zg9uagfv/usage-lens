# AGY Authentication Discovery Specification

## Requirement: AGY and Gemini are separate account sources

The app SHALL present AGY as a dedicated provider and SHALL NOT claim that a Gemini CLI credential is an AGY credential.

### Scenario: User has AGY but no Gemini CLI OAuth cache

- **Given** AGY local workspace data exists and `~/.gemini/oauth_creds.json` is absent.
- **When** UsageLens refreshes providers.
- **Then** it evaluates the AGY provider's supported AGY sources and does not instruct the user to provide the token in Gemini settings.

## Requirement: Discovery results are explainable without secrets

The AGY resolver SHALL retain a non-secret outcome for every attempted supported source.

### Scenario: Expected AGY auth file is missing

- **Given** `$AGY_AUTH_FILE` is unset and `~/.gemini/antigravity-cli/auth.json` does not exist.
- **When** AGY discovery runs.
- **Then** the final warning identifies missing AGY local auth as one possible cause and does not print a file's contents or token-like data.

### Scenario: Keychain is unavailable

- **Given** the allowed Keychain lookup returns a nonzero status, times out, or is denied.
- **When** AGY discovery runs.
- **Then** the app reports that the AGY Keychain credential could not be accessed, distinguishes it from an absent credential where safely possible, and suggests refreshing after unlocking/re-authenticating via AGY.
- **And** it SHALL NOT enumerate other Keychain entries or expose raw `security` output.

### Scenario: Test home isolation

- **Given** the effective `HOME` is not the login user's real home.
- **When** AGY discovery runs.
- **Then** it skips the real Keychain intentionally and reports a generic isolated-environment diagnostic.

## Requirement: Source discovery stays narrowly scoped

The implementation SHALL only inspect explicit environment overrides, a documented allowlist of AGY local paths, and a documented allowlist of Keychain service/account pairs.

### Scenario: Unsupported AGY version layout

- **Given** none of the allowlisted sources authenticates the user.
- **When** a later AGY release stores credentials elsewhere.
- **Then** UsageLens reports the unsupported/missing source state and does not recursively scan user directories, browser profiles, or all Keychain items.

## Requirement: Local and live fallback remain honest

### Scenario: Account discovery fails but transcripts exist

- **Given** no usable AGY credential is found and local transcript token records exist.
- **When** AGY refreshes.
- **Then** UsageLens may show local `today_tokens`, shows no fabricated quota percentage, and explains that live quota needs an AGY login source.

## Requirement: Documented sign-in and honest rejection

### Scenario: Profile cannot authenticate

- **Given** a missing, denied or unrefreshable AGY profile.
- **When** refresh completes.
- **Then** fixed guidance names AGY (`agy`, or verified `agy acp --login`), never invents `agy login`, borrows Gemini clients or modifies auth storage.
- **And** 403 alone SHALL NOT prove expiration; project permission/policy/entitlement may cause denial. The exact existing Keychain tuple remains unchanged absent versioned evidence.

## Requirement: Final subprocess environment is provider scoped

### Scenario: Inherited secrets and late overrides

- **Given** synthetic parent/override inputs include OAuth clients, API keys and future provider-prefixed variables.
- **When** any provider, nil or unknown provider launches, or DeepSeek invokes its external `zstd` helper.
- **Then** non-Gemini children receive no `GEMINI_*`, non-AGY children receive no `AGY_*`, and only DeepSeek's in-process balance check receives `DEEPSEEK_API_KEY` (never passed to `zstd`).
- **And** `zstd` receives only a minimal allowlisted environment (`PATH`, locale, `TMPDIR`) with explicit `Process.environment` so inherited parent variables cannot leak.
- **And** current OAuth-only children receive neither API-key variable nor design.md's ADC credential variables; Google project aliases are scoped to Gemini only.
- **And** late overrides cannot bypass the final boundary; actual child boolean assertions prove scope without printing secret values.

## Requirement: Native runtime bounds latency, memory, and numeric inputs fail-closed

### Scenario: Noncooperative Keychain or stuck decompressor

- **Given** an AGY Keychain lookup blocks synchronously or a DeepSeek `zstd` child hangs, ignores `SIGTERM`, exits nonzero, or exceeds the decompressed byte cap.
- **When** the probe or `ProbeRunner` runs under a bounded deadline or task cancellation.
- **Then** `SystemAgyKeychainReader` configures `LAContext(interactionNotAllowed: true)` for exact `(gemini, antigravity)` lookup, and `AgyNativeProbe` bounds Keychain execution off the cooperative pool with a 2-second wall-clock timeout and single-flight fail-closed gate.
- **And** `DeepSeekNativeProbe` enforces remaining scan budget and per-file timeout, escalates `SIGTERM` to `SIGKILL` with confirmed reap, rejects nonzero exit status, and caps buffered output.
- **And** `ProbeRunner` returns promptly at wall-clock deadline without waiting on noncooperative teardown, and synchronous log scans honor `Task.isCancelled`.

### Scenario: Oversized HTTP response or redirect

- **Given** a pinned HTTPS endpoint returns an oversized `Content-Length`, an oversized chunked body exceeding 1 MB, or any 3xx redirect.
- **When** `PinnedURLSessionTransport` executes the request via `URLSession`.
- **Then** declared oversized headers and 3xx redirects are rejected before buffering body bytes without following redirects, and oversized chunked streams are cancelled immediately at the 1 MB cap while streaming.

### Scenario: Extreme or overflowing numeric input

- **Given** local transcripts, rollout logs, or live responses contain extreme floating-point values (`1e100`, `1e308`, `Double(Int.max)`), `UInt64.max`, or token sums exceeding `Int.max`.
- **When** `NativeProbeSupport`, `CodexNativeProbe`, `AgyNativeProbe`, or `ProbeContract` parses them.
- **Then** checked conversions and overflow-checked additions never trap the process; invalid or overflowing inputs are skipped/nulled or fall back to safe defaults with non-secret diagnostic warnings.

## Requirement: Gemini OAuth project context is separate from authentication

### Scenario: Explicit Workspace or licensed Code Assist project

- **Given** valid Gemini OAuth credentials and project inputs.
- **When** project context is resolved.
- **Then** select the first nonempty trimmed `GEMINI_PROJECT_ID`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_PROJECT_ID`, preserving the existing app account override.
- **And** supply it in `loadCodeAssist.cloudaicompanionProject`, `metadata.duetProject`, and `retrieveUserQuota.project`; do not replace it after denial.
- **And** numeric project numbers yield non-echoing project-ID guidance; project variables never authenticate an account.

### Scenario: No configured project

- **Given** valid OAuth but no nonempty project input.
- **When** read-only discovery runs.
- **Then** send metadata-only loadCodeAssist and use a valid returned project for quota; missing/denied context produces honest guidance, no fabricated windows or onboarding writes.

### Scenario: Only API keys or project variables exist

- **Given** no supported OAuth credential and either API-key variable or project alias exists.
- **When** either OAuth quota probe runs.
- **Then** make zero authenticated quota calls; never promote API keys into Bearer auth, refresh fields, URL queries or quota JSON, nor infer an OAuth account.
- **And** Gemini project aliases do not affect AGY's independent `AGY_PROJECT_ID`.

## Requirement: Real bundled lifecycle evidence gates acceptance

### Scenario: Owner-controlled login/logout/re-login

- **Given** an identified bundle in the graphical user session, no manual token override and owner agreement to controlled logout.
- **When** design.md's protocol runs through AGY login and `/logout`, explicit app refresh and bundle relaunch.
- **Then** login/re-login/relaunch show live windows and logout clears or visibly invalidates old data; leave the owner signed in.
- **And** cancellation, denied access or still-valid upstream tokens are failure/inconclusive as applicable, never a pass.
- **And** retain only build metadata and reduced boolean/count/category/timing rows, no credentials, email/project IDs, auth URLs, raw logs or real-account screenshots.

