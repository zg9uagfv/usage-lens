# Native Swift Test & Remediation Evidence (`agy-auth-discovery-diagnostics`)

- **Timestamp**: 2026-11-22 14:42:45 +0800
- **HEAD Commit**: `11bc5649672a271e989f37818f55d7ebc7c113e4`
- **Dirty Swift Tree SHA-256** (31 non-`.build` `app/**/*.swift` files): `6d2f14251bab3c2d4f41527ed042dc288680772cedbca87e5ba312ccba0539f5`
- **Reproducible Hashing Recipe**:
  `LC_ALL=C find app -path 'app/.build' -prune -o -name '*.swift' -type f -print | LC_ALL=C sort | xargs cat | shasum -a 256`
- **Toolchain**: `swift-driver version: 1.168.6 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) | Target: arm64-apple-macosx27.0.0`
- **Focused Command**: `swift test --package-path app --filter "AgyProviderTests|NativeSafetyAndLifecycleTests"` -> **Exit Code**: `0` (`30/30` passed in 4.719s, `0` warnings)
- **Full Command**: `swift test --package-path app` -> **Exit Code**: `0`
- **Compiler Warnings**: `0`
- **Totals (Full Suite)**: `123` executed, `0` failed, `0` skipped (`UsageLensKitTests`: 90/90 passed; `UsageLensUITests`: 33/33 passed)

## Suite Breakdown (Full Suite)

| Target | Test Suite | Executed | Failures | Skips | Result |
| --- | --- | ---: | ---: | ---: | --- |
| `UsageLensUITests` | `DisplayScalingTests` | 14 | 0 | 0 | PASS |
| `UsageLensUITests` | `PanelRenderTests` | 19 | 0 | 0 | PASS |
| `UsageLensKitTests` | `AgyProviderTests` | 11 | 0 | 0 | PASS |
| `UsageLensKitTests` | `BlockingStateTests` | 6 | 0 | 0 | PASS |
| `UsageLensKitTests` | `ContractV2Tests` | 3 | 0 | 0 | PASS |
| `UsageLensKitTests` | `FormattingTests` | 9 | 0 | 0 | PASS |
| `UsageLensKitTests` | `GeminiAccountTests` | 11 | 0 | 0 | PASS |
| `UsageLensKitTests` | `NativeProbeRuntimeTests` | 4 | 0 | 0 | PASS |
| `UsageLensKitTests` | `NativeSafetyAndLifecycleTests` | 19 | 0 | 0 | PASS |
| `UsageLensKitTests` | `ProbeContractTests` | 7 | 0 | 0 | PASS |
| `UsageLensKitTests` | `ProbeRunnerDecodeTests` | 3 | 0 | 0 | PASS |
| `UsageLensKitTests` | `SecretRedactorTests` | 7 | 0 | 0 | PASS |
| `UsageLensKitTests` | `StateReducerTests` | 10 | 0 | 0 | PASS |
| **Total** | **13 suites** | **123** | **0** | **0** | **PASS** |

## Coverage Summary

1. **User-directed AGY Keychain OAuth Refresh Write-Back (`AgyNativeProbe.swift`, `NativeProbeSupport.swift`, `ProbeRunner.swift`)**:
   - Narrowly scoped `AgyKeychainWriteResult` + `AgyKeychainWriting` protocol; `SystemAgyKeychainReader` implements exact-tuple `(service: "gemini", account: "antigravity")` read (`SecItemCopyMatching`) and atomic in-place update (`SecItemUpdate`, updating only `kSecValueData` with `LAContext(interactionNotAllowed: true)`, never calling `SecItemAdd`/`SecItemDelete`, never enumerating, never widening ACLs).
   - Supports `expiry_date`, `expiry`, and `expires_at` (numeric/stringified epoch ms & sec, ISO8601/RFC3339 including Go `RFC3339Nano`, and `0` as expired) with `proactiveRefreshSkewSeconds = 60.0` and bounded single reactive 401 refresh. Fixed `NativeProbeSupport.parseExpiryEpoch` numeric-string ordering so stringified millisecond epochs normalize to seconds.
   - Strict pinned refresh via `https://oauth2.googleapis.com/token` with fail-closed validation of `access_token` (no control characters), `expires_in` (`1...31_536_000`), explicit future expiry fields, and optional rotated `refresh_token`.
   - Lossless format-preserving Keychain update (`go-keyring-base64:` vs raw JSON, nested `token` vs flat root, unknown root/token fields preserved, original expiry representation preserved, env-injected client IDs never persisted) with mandatory round-trip decode self-verification before `SecItemUpdate`.
   - Zero writes to local auth files (`auth.json`, `$AGY_AUTH_FILE`) and zero Keychain access under isolated `HOME`; fail-closed sanitized diagnostics on all write-back failure modes (`.missing`, `.denied`, `.timeout`, `.nonzero`, `.rejected`, read-only writer).
   - Shared `runKeychainBoundedAsync` + `AgyKeychainSingleFlightGate` + atomic `DispatchSourceTimer` lifecycle protection across both Keychain reads and Keychain writes.
   - Verified in 5 new tests:
     - `AgyProviderTests.testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields`
     - `AgyProviderTests.testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles`
     - `AgyProviderTests.testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain`
     - `AgyProviderTests.testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets`
     - `NativeSafetyAndLifecycleTests.testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach`
     - plus extended assertions in `NativeSafetyAndLifecycleTests.testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple`.
2. **Prior Native Swift Hardening & Timer Lifetime Fixes (Retained & Verified)**:
   - `DispatchSourceTimer` lifetime safety in `ProbeRunner` and `AgyNativeProbe` (`attachTimer` activation-under-lock, cancel/completion-before-attach, stress races).
   - `DeepSeekNativeProbe` minimal `zstd` child environment + watchdog/SIGKILL/reap/exit validation.
   - `PinnedURLSessionTransport` streaming 1 MB response cap, redirect rejection, and cancellation.
   - Checked numeric conversions and overflow-safe accumulation across `NativeProbeSupport`, `CodexNativeProbe`, `AgyNativeProbe`, `DeepSeekNativeProbe`, `ProbeContract`, `ProbeRunner`, and `Formatting`.

## Hashed Swift File Manifest (31 files, `LC_ALL=C sort`)

```text
app/Package.swift
app/Sources/UsageLens/MenuBarIcon.swift
app/Sources/UsageLens/UsageLensApp.swift
app/Sources/UsageLensKit/AgyNativeProbe.swift
app/Sources/UsageLensKit/CodexNativeProbe.swift
app/Sources/UsageLensKit/DeepSeekAPIKeyStore.swift
app/Sources/UsageLensKit/DeepSeekNativeProbe.swift
app/Sources/UsageLensKit/Formatting.swift
app/Sources/UsageLensKit/GeminiAccountStore.swift
app/Sources/UsageLensKit/GeminiNativeProbe.swift
app/Sources/UsageLensKit/NativeProbeSupport.swift
app/Sources/UsageLensKit/OpenCodeNativeProbe.swift
app/Sources/UsageLensKit/ProbeContract.swift
app/Sources/UsageLensKit/ProbeRunner.swift
app/Sources/UsageLensKit/Provider.swift
app/Sources/UsageLensKit/ProviderState.swift
app/Sources/UsageLensKit/SecretRedactor.swift
app/Sources/UsageLensUI/AboutPanelView.swift
app/Sources/UsageLensUI/DisplayScaling.swift
app/Sources/UsageLensUI/LaunchAtLoginManager.swift
app/Sources/UsageLensUI/MenuBarLabel.swift
app/Sources/UsageLensUI/PanelView.swift
app/Sources/UsageLensUI/SettingsPanelView.swift
app/Sources/UsageLensUI/Theme.swift
app/Sources/UsageLensUI/UsageStore.swift
app/Tests/UsageLensKitTests/AgyProviderTests.swift
app/Tests/UsageLensKitTests/GeminiAccountTests.swift
app/Tests/UsageLensKitTests/KitTests.swift
app/Tests/UsageLensKitTests/NativeSafetyAndLifecycleTests.swift
app/Tests/UsageLensUITests/DisplayScalingTests.swift
app/Tests/UsageLensUITests/PanelRenderTests.swift
```

## Scope Boundaries & Deferred Gates

- No real credentials, Keychain items, live network calls, or real user transcripts were read or executed.
- Packaging/build/restart (`app/Scripts/build-app.sh`) was intentionally not executed per task instructions (independent review first).
- Pre-existing uncommitted modifications to `probes/agy.py`, `probes/gemini.py`, `tests/test_agy.py`, and `tests/test_gemini.py` were not modified in this Swift-only pass and no Python test rerun is claimed here.
- Relay state (`.orca-relay/*`), `review_report.md`, Task 2 authorization/thermos resolution, Task 7 packaged AGY lifecycle verification, and Task 8 independent review remain open for their respective owners.

## Focused Command Output (`swift test --package-path app --filter "AgyProviderTests|NativeSafetyAndLifecycleTests"`, Exit Code 0)

```text
Building for debugging...
[1 / 3]
Build complete! (0.27 sec)
Test Suite 'Selected tests' started at 2026-11-22 14:42:13.824.
Test Suite 'UsageLensUITests.xctest' started at 2026-11-22 14:42:13.825.
Test Suite 'UsageLensUITests.xctest' passed at 2026-11-22 14:42:13.825.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-11-22 14:42:13.825.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
Test Suite 'Selected tests' started at 2026-11-22 14:42:13.885.
Test Suite 'UsageLensKitTests.xctest' started at 2026-11-22 14:42:13.885.
Test Suite 'AgyProviderTests' started at 2026-11-22 14:42:13.885.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgy403PermissionDenialVs401AndBoundedOAuthRefresh]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgy403PermissionDenialVs401AndBoundedOAuthRefresh]' passed (0.008 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainDiscoveryOutcomesExactTupleAndSecretFreeDiagnostics]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainDiscoveryOutcomesExactTupleAndSecretFreeDiagnostics]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeyringBase64LiveAggregationAndSourcePrecedence]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeyringBase64LiveAggregationAndSourcePrecedence]' passed (0.003 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyTodayTokensAndFallbackWhenUnauthenticated]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyTodayTokensAndFallbackWhenUnauthenticated]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerAgyTimeoutBudget]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerAgyTimeoutBudget]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerEnforcesFinalEnvironmentBoundaryAcrossAllProvidersUnknownAndNil]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerEnforcesFinalEnvironmentBoundaryAcrossAllProvidersUnknownAndNil]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProviderCatalogAgyMetadataAndDefaultOrdering]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProviderCatalogAgyMetadataAndDefaultOrdering]' passed (0.000 seconds).
Test Suite 'AgyProviderTests' passed at 2026-11-22 14:42:13.914.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.027 (0.028) seconds
Test Suite 'NativeSafetyAndLifecycleTests' started at 2026-11-22 14:42:13.914.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testAgyNativeTranscriptExtremeAndOverflowTokensDoNotTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testAgyNativeTranscriptExtremeAndOverflowTokensDoNotTrap]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCheckedNumericConversionAndOverflowBoundariesNeverTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCheckedNumericConversionAndOverflowBoundariesNeverTrap]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCodexNativeExtremeDurationsAndOverflowTokensDoNotTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCodexNativeExtremeDurationsAndOverflowTokensDoNotTrap]' passed (0.003 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testConcurrentTimerLifetimeStressForProbeRunnerAndAgyKeychain]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testConcurrentTimerLifetimeStressForProbeRunnerAndAgyKeychain]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdChildReceivesStrictMinimalEnvironmentOnly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdChildReceivesStrictMinimalEnvironmentOnly]' passed (0.617 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdWatchdogSIGKILLEscalationReapExitValidationAndBudget]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdWatchdogSIGKILLEscalationReapExitValidationAndBudget]' passed (3.012 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testKeychainContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testKeychainContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' passed (0.066 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainIsWallClockBoundedInProbeAndRunnerWithSingleFlight]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainIsWallClockBoundedInProbeAndRunnerWithSingleFlight]' passed (0.317 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach]' passed (0.157 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionCancelsOversizedChunkedStreamAtCapWithoutBufferingWholeBody]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionCancelsOversizedChunkedStreamAtCapWithoutBufferingWholeBody]' passed (0.094 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionChunkedExactCapBoundaryAndOneByteOver]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionChunkedExactCapBoundaryAndOneByteOver]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOverflowingContentLengthHeader]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOverflowingContentLengthHeader]' passed (0.034 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOversizedDeclaredContentLengthBeforeBufferingBody]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOversizedDeclaredContentLengthBeforeBufferingBody]' passed (0.038 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsRedirectsWithoutFollowingOrLeakingHeaders]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsRedirectsWithoutFollowingOrLeakingHeaders]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionTaskCancellationStopsActiveStreamPromptly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionTaskCancellationStopsActiveStreamPromptly]' passed (0.096 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' passed (0.067 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeRunnerAndKeychainEndToEndDeterministicCancelBeforeAttachAndFastCompletion]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeRunnerAndKeychainEndToEndDeterministicCancelBeforeAttachAndFastCompletion]' passed (0.148 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSynchronousScanHonorsCancellationPromptly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSynchronousScanHonorsCancellationPromptly]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple]' passed (0.017 seconds).
Test Suite 'NativeSafetyAndLifecycleTests' passed at 2026-11-22 14:42:18.614.
	 Executed 19 tests, with 0 failures (0 unexpected) in 4.692 (4.700) seconds
Test Suite 'UsageLensKitTests.xctest' passed at 2026-11-22 14:42:18.614.
	 Executed 30 tests, with 0 failures (0 unexpected) in 4.719 (4.729) seconds
Test Suite 'Selected tests' passed at 2026-11-22 14:42:18.614.
	 Executed 30 tests, with 0 failures (0 unexpected) in 4.719 (4.729) seconds
```

## Complete Full-Suite Command Output (`swift test --package-path app`, Sanitized Paths, Exit Code 0)

```text
Building for debugging...
[1 / 1]
Build complete! (0.27 sec)
Test Suite 'All tests' started at 2026-11-22 14:42:19.840.
Test Suite 'UsageLensUITests.xctest' started at 2026-11-22 14:42:19.840.
Test Suite 'DisplayScalingTests' started at 2026-11-22 14:42:19.840.
Test Case '-[UsageLensUITests.DisplayScalingTests testBaselineDisplayResolvesToOne]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testBaselineDisplayResolvesToOne]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testClampedWindowFrameConstrainsAllFourEdgesAndCorners]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testClampedWindowFrameConstrainsAllFourEdgesAndCorners]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testCompactAndFourteenInchDisplays]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testCompactAndFourteenInchDisplays]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testDisplayScaleControllerDeduplicatesUpdates]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testDisplayScaleControllerDeduplicatesUpdates]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testInvalidAndHeadlessInputsFallbackToStandard]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testInvalidAndHeadlessInputsFallbackToStandard]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testInvalidPhysicalEDIDValuesFallBackToLogicalOnly]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testInvalidPhysicalEDIDValuesFallBackToLogicalOnly]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testMinimumFontSizeFloor]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testMinimumFontSizeFloor]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testOffscreenRenderedViewsScaleAcrossFourDisplayProfiles]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testOffscreenRenderedViewsScaleAcrossFourDisplayProfiles]' passed (0.209 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testPortraitIsConstrainedByNarrowerWidthAxis]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testPortraitIsConstrainedByNarrowerWidthAxis]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testSixteenInchMacBookProScaling]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testSixteenInchMacBookProScaling]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testThirtyTwoInchDisplaysClampAtUpperBounds]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testThirtyTwoInchDisplaysClampAtUpperBounds]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testTwentySevenInchExternalMonitorsAcrossScalingModes]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testTwentySevenInchExternalMonitorsAcrossScalingModes]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testUltrawideDoesNotOverScale]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testUltrawideDoesNotOverScale]' passed (0.000 seconds).
Test Case '-[UsageLensUITests.DisplayScalingTests testVisibleSizeClamping]' started.
Test Case '-[UsageLensUITests.DisplayScalingTests testVisibleSizeClamping]' passed (0.000 seconds).
Test Suite 'DisplayScalingTests' passed at 2026-11-22 14:42:20.053.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.211 (0.212) seconds
Test Suite 'PanelRenderTests' started at 2026-11-22 14:42:20.053.
Test Case '-[UsageLensUITests.PanelRenderTests testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance]' passed (0.541 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testAgyPanelAndSettingsHostedRenderAcrossThemesAndScales]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testAgyPanelAndSettingsHostedRenderAcrossThemesAndScales]' passed (5.875 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testCodexTabShowsWindows]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testCodexTabShowsWindows]' passed (0.024 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testDebugSummaryRedactsSecrets]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testDebugSummaryRedactsSecrets]' passed (0.001 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testDeepSeekTabWithoutKey]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testDeepSeekTabWithoutKey]' passed (0.019 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testDeleteCredentialsDuringInFlightRefreshClearsAndCoalesces]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testDeleteCredentialsDuringInFlightRefreshClearsAndCoalesces]' passed (0.001 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testEmptyProviderShowsNoData]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testEmptyProviderShowsNoData]' passed (0.013 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testExpiredWindowsRender]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testExpiredWindowsRender]' passed (0.013 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiAuthErrorRendersFailedAndStaleStates]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiAuthErrorRendersFailedAndStaleStates]' passed (0.027 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiConfiguredShows5hAnd7dWindows]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiConfiguredShows5hAnd7dWindows]' passed (0.013 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiNeedsAccountRendersEmptyGuidance]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testGeminiNeedsAccountRendersEmptyGuidance]' passed (0.012 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testIncompatibleSchemaShowsNoNumbers]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testIncompatibleSchemaShowsNoNumbers]' passed (0.011 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testMenuBarLabelUsesMostTenseWindow]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testMenuBarLabelUsesMostTenseWindow]' passed (0.004 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testMissingProbeShowsNoData]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testMissingProbeShowsNoData]' passed (0.012 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testRefreshIfNeededForExternalAuthRefreshesAgyWithoutDisturbingGemini]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testRefreshIfNeededForExternalAuthRefreshesAgyWithoutDisturbingGemini]' passed (0.031 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testSaveCredentialsDuringInFlightRefreshInvalidatesUnconfiguredResult]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testSaveCredentialsDuringInFlightRefreshInvalidatesUnconfiguredResult]' passed (0.001 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testSettingsAndGeminiPanelAcrossDisplayProfilesAndThemes]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testSettingsAndGeminiPanelAcrossDisplayProfilesAndThemes]' passed (13.068 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testStaleCodexKeepsLastValuesDimmed]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testStaleCodexKeepsLastValuesDimmed]' passed (0.033 seconds).
Test Case '-[UsageLensUITests.PanelRenderTests testStaleDataRendersDimmed]' started.
Test Case '-[UsageLensUITests.PanelRenderTests testStaleDataRendersDimmed]' passed (0.015 seconds).
Test Suite 'PanelRenderTests' passed at 2026-11-22 14:42:39.769.
	 Executed 19 tests, with 0 failures (0 unexpected) in 19.715 (19.716) seconds
Test Suite 'UsageLensUITests.xctest' passed at 2026-11-22 14:42:39.769.
	 Executed 33 tests, with 0 failures (0 unexpected) in 19.926 (19.929) seconds
Test Suite 'All tests' passed at 2026-11-22 14:42:39.769.
	 Executed 33 tests, with 0 failures (0 unexpected) in 19.926 (19.930) seconds
rendered-hosted: <REPO_ROOT>/app/.preview/22-panel-agy-missing.png 680x578
rendered-hosted: <REPO_ROOT>/app/.preview/23-panel-agy-denied.png 680x578
rendered-hosted: <REPO_ROOT>/app/.preview/24-panel-agy-isolated.png 680x604
rendered-hosted: <REPO_ROOT>/app/.preview/25-panel-agy-expired.png 680x578
rendered-hosted: <REPO_ROOT>/app/.preview/26-panel-agy-forbidden-403.png 680x604
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-tech-compact.png 578x610
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-tech-compact.png 578x452
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-tech-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-tech-standard.png 680x714
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-tech-standard.png 680x530
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-tech-standard.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-tech-comfortable.png 822x858
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-tech-comfortable.png 822x632
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-tech-comfortable.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-tech-large.png 1034x1056
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-tech-large.png 1034x780
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-tech-large.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-anime-compact.png 578x610
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-anime-compact.png 578x452
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-anime-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-anime-standard.png 680x714
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-anime-standard.png 680x530
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-anime-standard.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-anime-comfortable.png 822x858
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-anime-comfortable.png 822x632
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-anime-comfortable.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-anime-large.png 1034x1056
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-anime-large.png 1034x780
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-anime-large.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-system-compact.png 578x610
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-system-compact.png 578x452
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-system-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-system-standard.png 680x714
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-system-standard.png 680x530
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-system-standard.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-system-comfortable.png 822x858
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-system-comfortable.png 822x632
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-system-comfortable.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/19-panel-agy-live-system-large.png 1034x1056
rendered-hosted: <REPO_ROOT>/app/.preview/20-panel-agy-fallback-system-large.png 1034x780
rendered-hosted: <REPO_ROOT>/app/.preview/21-settings-agy-active-system-large.png 1094x1580
rendered: <REPO_ROOT>/app/.preview/01-codex.png 728x762
rendered: <REPO_ROOT>/app/.preview/02-deepseek.png 728x582
rendered: <REPO_ROOT>/app/.preview/05-codex-empty.png 728x525
rendered: <REPO_ROOT>/app/.preview/07-codex-expired-windows.png 728x614
rendered: <REPO_ROOT>/app/.preview/12-gemini-auth-failed.png 728x551
rendered: <REPO_ROOT>/app/.preview/13-gemini-auth-stale.png 728x758
rendered: <REPO_ROOT>/app/.preview/11-gemini-configured.png 728x614
rendered: <REPO_ROOT>/app/.preview/10-gemini-needs-account.png 728x599
rendered: <REPO_ROOT>/app/.preview/09-codex-incompatible-schema.png 728x525
rendered: <REPO_ROOT>/app/.preview/06-menubar.png 244x77
rendered: <REPO_ROOT>/app/.preview/03-deepseek-missing-probe.png 728x555
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-tech-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-tech-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-tech-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-tech-compact.png 578x476
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-tech-compact.png 578x484
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-tech-compact.png 578x434
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-tech-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-tech-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-tech-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-tech-baseline.png 680x552
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-tech-baseline.png 680x566
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-tech-baseline.png 680x504
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-tech-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-tech-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-tech-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-tech-mbp16.png 822x664
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-tech-mbp16.png 822x682
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-tech-mbp16.png 822x606
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-tech-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-tech-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-tech-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-tech-monitor27.png 1034x814
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-tech-monitor27.png 1034x838
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-tech-monitor27.png 1034x744
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-anime-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-anime-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-anime-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-anime-compact.png 578x476
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-anime-compact.png 578x484
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-anime-compact.png 578x434
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-anime-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-anime-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-anime-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-anime-baseline.png 680x552
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-anime-baseline.png 680x566
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-anime-baseline.png 680x504
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-anime-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-anime-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-anime-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-anime-mbp16.png 822x664
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-anime-mbp16.png 822x682
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-anime-mbp16.png 822x606
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-anime-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-anime-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-anime-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-anime-monitor27.png 1034x814
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-anime-monitor27.png 1034x838
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-anime-monitor27.png 1034x744
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-system-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-system-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-system-compact.png 612x884
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-system-compact.png 578x476
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-system-compact.png 578x484
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-system-compact.png 578x434
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-system-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-system-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-system-baseline.png 720x1040
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-system-baseline.png 680x552
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-system-baseline.png 680x566
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-system-baseline.png 680x504
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-system-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-system-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-system-mbp16.png 872x1258
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-system-mbp16.png 822x664
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-system-mbp16.png 822x682
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-system-mbp16.png 822x606
rendered-hosted: <REPO_ROOT>/app/.preview/14-settings-gemini-unconfigured-system-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15-settings-gemini-configured-system-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/15b-settings-gemini-local-cli-system-monitor27.png 1094x1580
rendered-hosted: <REPO_ROOT>/app/.preview/16-panel-gemini-needs-account-system-monitor27.png 1034x814
rendered-hosted: <REPO_ROOT>/app/.preview/17-panel-gemini-configured-system-monitor27.png 1034x838
rendered-hosted: <REPO_ROOT>/app/.preview/18-panel-gemini-auth-error-system-monitor27.png 1034x744
rendered: <REPO_ROOT>/app/.preview/04-codex-stale.png 728x880
rendered: <REPO_ROOT>/app/.preview/08-codex-stale-data.png 728x664
Test Suite 'All tests' started at 2026-11-22 14:42:39.861.
Test Suite 'UsageLensKitTests.xctest' started at 2026-11-22 14:42:39.862.
Test Suite 'AgyProviderTests' started at 2026-11-22 14:42:39.862.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgy403PermissionDenialVs401AndBoundedOAuthRefresh]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgy403PermissionDenialVs401AndBoundedOAuthRefresh]' passed (0.009 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainDiscoveryOutcomesExactTupleAndSecretFreeDiagnostics]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainDiscoveryOutcomesExactTupleAndSecretFreeDiagnostics]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeyringBase64LiveAggregationAndSourcePrecedence]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyKeyringBase64LiveAggregationAndSourcePrecedence]' passed (0.003 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyTodayTokensAndFallbackWhenUnauthenticated]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testAgyTodayTokensAndFallbackWhenUnauthenticated]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerAgyTimeoutBudget]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerAgyTimeoutBudget]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerEnforcesFinalEnvironmentBoundaryAcrossAllProvidersUnknownAndNil]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProbeRunnerEnforcesFinalEnvironmentBoundaryAcrossAllProvidersUnknownAndNil]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.AgyProviderTests testProviderCatalogAgyMetadataAndDefaultOrdering]' started.
Test Case '-[UsageLensKitTests.AgyProviderTests testProviderCatalogAgyMetadataAndDefaultOrdering]' passed (0.000 seconds).
Test Suite 'AgyProviderTests' passed at 2026-11-22 14:42:39.891.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.028 (0.029) seconds
Test Suite 'BlockingStateTests' started at 2026-11-22 14:42:39.891.
Test Case '-[UsageLensKitTests.BlockingStateTests testBenignWarningStillShowsInMenuBar]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testBenignWarningStillShowsInMenuBar]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.BlockingStateTests testDataStaleIsWarningAndExcludedFromMenuBar]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testDataStaleIsWarningAndExcludedFromMenuBar]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.BlockingStateTests testExpiredWindowExcludedFromMenuBar]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testExpiredWindowExcludedFromMenuBar]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.BlockingStateTests testFailedStaleValuesExcludedFromMenuBar]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testFailedStaleValuesExcludedFromMenuBar]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.BlockingStateTests testFreshWindowStillShowOnMenuBar]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testFreshWindowStillShowOnMenuBar]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.BlockingStateTests testIncompatibleSchemaClearsPreviousValues]' started.
Test Case '-[UsageLensKitTests.BlockingStateTests testIncompatibleSchemaClearsPreviousValues]' passed (0.000 seconds).
Test Suite 'BlockingStateTests' passed at 2026-11-22 14:42:39.893.
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'ContractV2Tests' started at 2026-11-22 14:42:39.893.
Test Case '-[UsageLensKitTests.ContractV2Tests testDecodesObservedAtStaleAndExpired]' started.
Test Case '-[UsageLensKitTests.ContractV2Tests testDecodesObservedAtStaleAndExpired]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ContractV2Tests testSchemaMismatchIsTreatedAsIncompatible]' started.
Test Case '-[UsageLensKitTests.ContractV2Tests testSchemaMismatchIsTreatedAsIncompatible]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.ContractV2Tests testStaleDefaultsToFalseAndFallsBackToGeneratedAt]' started.
Test Case '-[UsageLensKitTests.ContractV2Tests testStaleDefaultsToFalseAndFallsBackToGeneratedAt]' passed (0.000 seconds).
Test Suite 'ContractV2Tests' passed at 2026-11-22 14:42:39.894.
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'FormattingTests' started at 2026-11-22 14:42:39.894.
Test Case '-[UsageLensKitTests.FormattingTests testDataAgeAndExpiredMessages]' started.
Test Case '-[UsageLensKitTests.FormattingTests testDataAgeAndExpiredMessages]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testFraction]' started.
Test Case '-[UsageLensKitTests.FormattingTests testFraction]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testMoney]' started.
Test Case '-[UsageLensKitTests.FormattingTests testMoney]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testPercent]' started.
Test Case '-[UsageLensKitTests.FormattingTests testPercent]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testResetCountdown]' started.
Test Case '-[UsageLensKitTests.FormattingTests testResetCountdown]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testSourceAndBasisLabels]' started.
Test Case '-[UsageLensKitTests.FormattingTests testSourceAndBasisLabels]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testTokenCount]' started.
Test Case '-[UsageLensKitTests.FormattingTests testTokenCount]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testUpdatedText]' started.
Test Case '-[UsageLensKitTests.FormattingTests testUpdatedText]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.FormattingTests testWindowExpiredFlagAndFallback]' started.
Test Case '-[UsageLensKitTests.FormattingTests testWindowExpiredFlagAndFallback]' passed (0.000 seconds).
Test Suite 'FormattingTests' passed at 2026-11-22 14:42:39.896.
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds
Test Suite 'GeminiAccountTests' started at 2026-11-22 14:42:39.896.
Test Case '-[UsageLensKitTests.GeminiAccountTests testAuthFailureAfterUnconfiguredOrEmptyQuotaBecomesFailed]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testAuthFailureAfterUnconfiguredOrEmptyQuotaBecomesFailed]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testDetectLocalCLIAuthAndCredentialSourcePriority]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testDetectLocalCLIAuthAndCredentialSourcePriority]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiAccountStoreCRUDInMemory]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiAccountStoreCRUDInMemory]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiAccountValidationSuccessAndFailureNativeSwift]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiAccountValidationSuccessAndFailureNativeSwift]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNativeDelayedMultiStepRefreshAndBoundedDeadline]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNativeDelayedMultiStepRefreshAndBoundedDeadline]' passed (0.560 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNoProjectDiscoveryMissingProject401Refresh403DenialAndAPIKeyIsolation]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNoProjectDiscoveryMissingProject401Refresh403DenialAndAPIKeyIsolation]' passed (0.008 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNumericProjectNumberRejectedWithoutEchoingInput]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiNumericProjectNumberRejectedWithoutEchoingInput]' passed (0.002 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiProjectPrecedenceTrimmingAndLoadQuotaSemantics]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiProjectPrecedenceTrimmingAndLoadQuotaSemantics]' passed (0.012 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiStateTransitionsAndMenuBarTension]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testGeminiStateTransitionsAndMenuBarTension]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testProviderCatalogGeminiFlags]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testProviderCatalogGeminiFlags]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.GeminiAccountTests testSecretRedactorRedactsGoogleOAuthTokens]' started.
Test Case '-[UsageLensKitTests.GeminiAccountTests testSecretRedactorRedactsGoogleOAuthTokens]' passed (0.001 seconds).
Test Suite 'GeminiAccountTests' passed at 2026-11-22 14:42:40.485.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.587 (0.589) seconds
Test Suite 'NativeProbeRuntimeTests' started at 2026-11-22 14:42:40.485.
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testCodexNativeProbeLiveFallbackAndTodayTokens]' started.
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testCodexNativeProbeLiveFallbackAndTodayTokens]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testDeepSeekNativeProbeNoKeyBalanceAndProjcacheSpend]' started.
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testDeepSeekNativeProbeNoKeyBalanceAndProjcacheSpend]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testOpenCodeNativeProbeReturnsMissingWithoutPython]' started.
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testOpenCodeNativeProbeReturnsMissingWithoutPython]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testPinnedHTTPSURLValidation]' started.
Test Case '-[UsageLensKitTests.NativeProbeRuntimeTests testPinnedHTTPSURLValidation]' passed (0.000 seconds).
Test Suite 'NativeProbeRuntimeTests' passed at 2026-11-22 14:42:40.498.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.012 (0.012) seconds
Test Suite 'NativeSafetyAndLifecycleTests' started at 2026-11-22 14:42:40.498.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testAgyNativeTranscriptExtremeAndOverflowTokensDoNotTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testAgyNativeTranscriptExtremeAndOverflowTokensDoNotTrap]' passed (0.008 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCheckedNumericConversionAndOverflowBoundariesNeverTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCheckedNumericConversionAndOverflowBoundariesNeverTrap]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCodexNativeExtremeDurationsAndOverflowTokensDoNotTrap]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testCodexNativeExtremeDurationsAndOverflowTokensDoNotTrap]' passed (0.005 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testConcurrentTimerLifetimeStressForProbeRunnerAndAgyKeychain]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testConcurrentTimerLifetimeStressForProbeRunnerAndAgyKeychain]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdChildReceivesStrictMinimalEnvironmentOnly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdChildReceivesStrictMinimalEnvironmentOnly]' passed (0.483 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdWatchdogSIGKILLEscalationReapExitValidationAndBudget]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testDeepSeekZstdWatchdogSIGKILLEscalationReapExitValidationAndBudget]' passed (2.917 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testKeychainContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testKeychainContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' passed (0.063 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainIsWallClockBoundedInProbeAndRunnerWithSingleFlight]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainIsWallClockBoundedInProbeAndRunnerWithSingleFlight]' passed (0.315 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach]' passed (0.157 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionCancelsOversizedChunkedStreamAtCapWithoutBufferingWholeBody]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionCancelsOversizedChunkedStreamAtCapWithoutBufferingWholeBody]' passed (0.095 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionChunkedExactCapBoundaryAndOneByteOver]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionChunkedExactCapBoundaryAndOneByteOver]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOverflowingContentLengthHeader]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOverflowingContentLengthHeader]' passed (0.038 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOversizedDeclaredContentLengthBeforeBufferingBody]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsOversizedDeclaredContentLengthBeforeBufferingBody]' passed (0.036 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsRedirectsWithoutFollowingOrLeakingHeaders]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionRejectsRedirectsWithoutFollowingOrLeakingHeaders]' passed (0.004 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionTaskCancellationStopsActiveStreamPromptly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testPinnedURLSessionTaskCancellationStopsActiveStreamPromptly]' passed (0.102 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout]' passed (0.067 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeRunnerAndKeychainEndToEndDeterministicCancelBeforeAttachAndFastCompletion]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testProbeRunnerAndKeychainEndToEndDeterministicCancelBeforeAttachAndFastCompletion]' passed (0.148 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSynchronousScanHonorsCancellationPromptly]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSynchronousScanHonorsCancellationPromptly]' passed (0.007 seconds).
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple]' started.
Test Case '-[UsageLensKitTests.NativeSafetyAndLifecycleTests testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple]' passed (0.016 seconds).
Test Suite 'NativeSafetyAndLifecycleTests' passed at 2026-11-22 14:42:44.984.
	 Executed 19 tests, with 0 failures (0 unexpected) in 4.477 (4.486) seconds
Test Suite 'ProbeContractTests' started at 2026-11-22 14:42:44.984.
Test Case '-[UsageLensKitTests.ProbeContractTests testDecodesFullSample]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testDecodesFullSample]' passed (0.003 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testGarbageIsNotParsed]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testGarbageIsNotParsed]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testMissingWindowsBecomesEmptyArray]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testMissingWindowsBecomesEmptyArray]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testNullUsedPercentStaysNilNotZero]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testNullUsedPercentStaysNilNotZero]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testSchemaMismatchIsReported]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testSchemaMismatchIsReported]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testStringlyTypedNumbersAreAccepted]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testStringlyTypedNumbersAreAccepted]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeContractTests testWarningToleratesSingleString]' started.
Test Case '-[UsageLensKitTests.ProbeContractTests testWarningToleratesSingleString]' passed (0.000 seconds).
Test Suite 'ProbeContractTests' passed at 2026-11-22 14:42:44.993.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.007 (0.009) seconds
Test Suite 'ProbeRunnerDecodeTests' started at 2026-11-22 14:42:44.993.
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testBrokenStdoutUsesStderrLine]' started.
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testBrokenStdoutUsesStderrLine]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testNonZeroExitWithCleanJSONIsNotAFailure]' started.
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testNonZeroExitWithCleanJSONIsNotAFailure]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testNonZeroExitWithJSONKeepsEnvelope]' started.
Test Case '-[UsageLensKitTests.ProbeRunnerDecodeTests testNonZeroExitWithJSONKeepsEnvelope]' passed (0.001 seconds).
Test Suite 'ProbeRunnerDecodeTests' passed at 2026-11-22 14:42:44.996.
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds
Test Suite 'SecretRedactorTests' started at 2026-11-22 14:42:44.996.
Test Case '-[UsageLensKitTests.SecretRedactorTests testKeepsNormalChineseText]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testKeepsNormalChineseText]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsBearerToken]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsBearerToken]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsKeyValueInURL]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsKeyValueInURL]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsLongRandomRun]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsLongRandomRun]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsOpenAIKey]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testRedactsOpenAIKey]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testStderrReachingUIIsRedacted]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testStderrReachingUIIsRedacted]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.SecretRedactorTests testWarningsAreRedactedToo]' started.
Test Case '-[UsageLensKitTests.SecretRedactorTests testWarningsAreRedactedToo]' passed (0.000 seconds).
Test Suite 'SecretRedactorTests' passed at 2026-11-22 14:42:45.000.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
Test Suite 'StateReducerTests' started at 2026-11-22 14:42:45.000.
Test Case '-[UsageLensKitTests.StateReducerTests testFailureKeepsLastValueAndMarksStale]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testFailureKeepsLastValueAndMarksStale]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testFailureWithoutDataIsFailed]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testFailureWithoutDataIsFailed]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testMissingProbeClearsData]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testMissingProbeClearsData]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testMostTenseNilWhenNoPercentAvailable]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testMostTenseNilWhenNoPercentAvailable]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testMostTensePicksHighestPercent]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testMostTensePicksHighestPercent]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testNoWindowsNoMetricsIsEmptyNotZero]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testNoWindowsNoMetricsIsEmptyNotZero]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testSpendValueFiltersContradictoryWarnings]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testSpendValueFiltersContradictoryWarnings]' passed (0.001 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testWarningsNotFilteredWithoutSpend]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testWarningsNotFilteredWithoutSpend]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testWarningsOnlyIsWarningNotOk]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testWarningsOnlyIsWarningNotOk]' passed (0.000 seconds).
Test Case '-[UsageLensKitTests.StateReducerTests testWarningSteersStatus]' started.
Test Case '-[UsageLensKitTests.StateReducerTests testWarningSteersStatus]' passed (0.000 seconds).
Test Suite 'StateReducerTests' passed at 2026-11-22 14:42:45.006.
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds
Test Suite 'UsageLensKitTests.xctest' passed at 2026-11-22 14:42:45.006.
	 Executed 90 tests, with 0 failures (0 unexpected) in 5.124 (5.144) seconds
Test Suite 'All tests' passed at 2026-11-22 14:42:45.006.
	 Executed 90 tests, with 0 failures (0 unexpected) in 5.124 (5.144) seconds
◇ Test run started.
↳ Testing Library Version: 2403
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
↳ Testing Library Version: 2403
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```
