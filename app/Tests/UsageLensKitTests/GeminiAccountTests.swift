import XCTest
@testable import UsageLensKit

final class GeminiAccountTests: XCTestCase {
    func testProviderCatalogGeminiFlags() {
        XCTAssertTrue(ProviderCatalog.gemini.requiresAccount)
        XCTAssertTrue(ProviderCatalog.gemini.requiresCredentials)
        XCTAssertFalse(ProviderCatalog.gemini.requiresAPIKey)

        XCTAssertTrue(ProviderCatalog.deepseek.requiresAPIKey)
        XCTAssertTrue(ProviderCatalog.deepseek.requiresCredentials)
        XCTAssertFalse(ProviderCatalog.deepseek.requiresAccount)

        XCTAssertFalse(ProviderCatalog.codex.requiresCredentials)
    }

    func testGeminiAccountStoreCRUDInMemory() throws {
        let storage = InMemoryGeminiKeychainStorage()
        XCTAssertFalse(GeminiAccountStore.hasSavedAccount(storage: storage))
        XCTAssertNil(GeminiAccountStore.savedAccountEmail(storage: storage))
        XCTAssertNil(GeminiAccountStore.load(storage: storage))

        XCTAssertThrowsError(
            try GeminiAccountStore.save(email: "  ", accessToken: "ya29.valid", storage: storage)
        ) { error in
            XCTAssertEqual(error as? GeminiAccountStoreError, .emptyEmail)
        }
        XCTAssertThrowsError(
            try GeminiAccountStore.save(email: "user@gmail.com", accessToken: " \n ", storage: storage)
        ) { error in
            XCTAssertEqual(error as? GeminiAccountStoreError, .emptyAccessToken)
        }

        try GeminiAccountStore.save(
            email: "  user@gmail.com  ",
            accessToken: "  ya29.test_token_12345  ",
            projectID: "  projects/demo  ",
            storage: storage
        )
        XCTAssertTrue(GeminiAccountStore.hasSavedAccount(storage: storage))
        XCTAssertEqual(GeminiAccountStore.savedAccountEmail(storage: storage), "user@gmail.com")
        XCTAssertEqual(
            GeminiAccountStore.load(storage: storage),
            GeminiAccount(email: "user@gmail.com", accessToken: "ya29.test_token_12345", projectID: "projects/demo")
        )

        // 更新覆盖
        try GeminiAccountStore.save(
            email: "other@gmail.com",
            accessToken: "ya29.updated_token_999",
            projectID: "   ",
            storage: storage
        )
        XCTAssertEqual(GeminiAccountStore.savedAccountEmail(storage: storage), "other@gmail.com")
        XCTAssertEqual(
            GeminiAccountStore.load(storage: storage),
            GeminiAccount(email: "other@gmail.com", accessToken: "ya29.updated_token_999", projectID: nil)
        )

        // 删除
        try GeminiAccountStore.delete(storage: storage)
        XCTAssertFalse(GeminiAccountStore.hasSavedAccount(storage: storage))
        XCTAssertNil(GeminiAccountStore.savedAccountEmail(storage: storage))
        XCTAssertNil(GeminiAccountStore.load(storage: storage))
    }

    func testGeminiAccountValidationSuccessAndFailure() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache/gemini-validation-tests", isDirectory: true)
        let probes = root.appendingPathComponent("probes", isDirectory: true)
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)

        let script = probes.appendingPathComponent("gemini.py")
        let scriptText = """
        import json, os, sys
        email = os.environ.get("GEMINI_ACCOUNT_EMAIL", "")
        token = os.environ.get("GEMINI_ACCESS_TOKEN", "")
        if token == "ya29.good_token_12345":
            out = {
                "schema": "usage-lens/probe@1",
                "provider": "gemini",
                "account": {"label": email, "plan": "pro"},
                "windows": [
                    {"id": "5h", "label": "5 小时", "used_percent": 25, "window_seconds": 18000, "basis": "server"},
                    {"id": "7d", "label": "7 天", "used_percent": 40, "window_seconds": 604800, "basis": "server"}
                ],
                "warnings": [],
                "error": None
            }
            print(json.dumps(out, ensure_ascii=False))
            sys.exit(0)
        out = {
            "schema": "usage-lens/probe@1",
            "provider": "gemini",
            "account": {"label": email, "plan": None},
            "windows": [],
            "warnings": [],
            "error": "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"
        }
        print(json.dumps(out, ensure_ascii=False))
        sys.exit(1)
        """
        try scriptText.write(to: script, atomically: true, encoding: .utf8)

        let runner = ProbeRunner(
            root: root,
            timeout: 5,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )

        let emptyEmailMsg = await GeminiAccountStore.validationMessage(email: "", accessToken: "ya29.good_token_12345", runner: runner)
        XCTAssertEqual(emptyEmailMsg, "Gemini 账号邮箱不能为空")

        let emptyTokenMsg = await GeminiAccountStore.validationMessage(email: "user@gmail.com", accessToken: " ", runner: runner)
        XCTAssertEqual(emptyTokenMsg, "访问令牌不能为空")

        let okMsg = await GeminiAccountStore.validationMessage(
            email: "user@gmail.com",
            accessToken: "ya29.good_token_12345",
            runner: runner
        )
        XCTAssertNil(okMsg)

        let failMsg = await GeminiAccountStore.validationMessage(
            email: "user@gmail.com",
            accessToken: "ya29.expired_token",
            runner: runner
        )
        XCTAssertTrue(failMsg?.contains("HTTP 401") ?? false, failMsg ?? "nil")
    }

    func testProbeRunnerIsolatesGeminiCredentialsByProvider() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache/gemini-env-isolation-tests", isDirectory: true)
        let probes = root.appendingPathComponent("probes", isDirectory: true)
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)

        let echoScript = """
        import json, os
        has_token = "GEMINI_ACCESS_TOKEN" in os.environ
        email = os.environ.get("GEMINI_ACCOUNT_EMAIL")
        project = os.environ.get("GEMINI_PROJECT_ID")
        print(json.dumps({
            "schema": "usage-lens/probe@1",
            "provider": "test",
            "account": {"label": email, "plan": project},
            "windows": [],
            "warnings": ["has_gemini_token=" + str(has_token)],
            "error": None
        }))
        """
        try echoScript.write(to: probes.appendingPathComponent("gemini.py"), atomically: true, encoding: .utf8)
        try echoScript.write(to: probes.appendingPathComponent("codex.py"), atomically: true, encoding: .utf8)
        try echoScript.write(to: probes.appendingPathComponent("deepseek.py"), atomically: true, encoding: .utf8)

        let account = GeminiAccount(email: "user@gmail.com", accessToken: "ya29.secret_for_gemini_only", projectID: "proj-1")
        let runner = ProbeRunner(
            root: root,
            timeout: 5,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { account }
        )

        let geminiReport = await runner.report(for: ProviderCatalog.gemini)
        XCTAssertEqual(geminiReport.envelope?.account?.label, "user@gmail.com")
        XCTAssertEqual(geminiReport.envelope?.account?.plan, "proj-1")
        XCTAssertEqual(geminiReport.warnings, ["has_gemini_token=True"])

        let codexReport = await runner.report(for: ProviderCatalog.codex)
        XCTAssertNil(codexReport.envelope?.account?.label)
        XCTAssertEqual(codexReport.warnings, ["has_gemini_token=False"])

        let deepseekReport = await runner.report(for: ProviderCatalog.deepseek)
        XCTAssertNil(deepseekReport.envelope?.account?.label)
        XCTAssertEqual(deepseekReport.warnings, ["has_gemini_token=False"])
    }

    func testSecretRedactorRedactsGoogleOAuthTokens() {
        let access = SecretRedactor.redact("请求失败 ya29.a0AfB_byTestToken12345 请重试")
        XCTAssertTrue(access.contains("***"))
        XCTAssertFalse(access.contains("ya29."))
        XCTAssertTrue(access.contains("请重试"))

        let refresh = SecretRedactor.redact("refresh 1//0eAbCdEfGhIjKlMnOpQrStUvWxYz end")
        XCTAssertTrue(refresh.contains("***"))
        XCTAssertFalse(refresh.contains("1//"))
        XCTAssertTrue(refresh.contains("end"))
    }

    func testGeminiStateTransitionsAndMenuBarTension() {
        let now = Date()
        var state = ProviderState(provider: ProviderCatalog.gemini)

        // 1. 未配置账号：不进入菜单栏
        let unconfigured = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"]
            ),
            finishedAt: now
        )
        state = ProviderReducer.apply(unconfigured, to: state)
        XCTAssertEqual(state.status, .warning)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertNil(state.accountLabel)
        XCTAssertNil(Tension.mostTense(in: [state], now: now))

        // 2. 配置账号后返回 5h 和 7d 窗口：进入菜单栏取最紧张窗口
        let configured = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: "pro"),
                generatedAt: now,
                observedAt: now,
                windows: [
                    ProbeWindow(id: "5h", label: "5 小时", usedPercent: 35, windowSeconds: 18_000, resetsAt: now.addingTimeInterval(7200), basis: "server"),
                    ProbeWindow(id: "7d", label: "7 天", usedPercent: 68, windowSeconds: 604_800, resetsAt: now.addingTimeInterval(3 * 86_400), basis: "server"),
                ]
            ),
            finishedAt: now
        )
        state = ProviderReducer.apply(configured, to: state)
        XCTAssertEqual(state.status, .ok)
        XCTAssertEqual(state.accountLabel, "user@gmail.com")
        XCTAssertEqual(state.windows.count, 2)
        XCTAssertEqual(Tension.mostTense(in: [state], now: now)?.compactLabel, "Gemini 7d 68%")

        // 3. 凭据过期（HTTP 401 带空 windows JSON）：有旧值时进入 .stale 并保留上次 5h/7d 值，退出菜单栏
        let expiredWithEmptyEnvelope = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: nil),
                windows: [],
                error: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"
            ),
            failure: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号",
            finishedAt: now.addingTimeInterval(60)
        )
        let staleState = ProviderReducer.apply(expiredWithEmptyEnvelope, to: state)
        XCTAssertEqual(staleState.status, .stale)
        XCTAssertTrue(staleState.isStale)
        XCTAssertEqual(staleState.windows.count, 2)
        XCTAssertNil(Tension.mostTense(in: [staleState], now: now))

        // 4. 无旧值时遇到 HTTP 401 带空 windows JSON：进入 .failed
        let freshFailed = ProviderReducer.apply(expiredWithEmptyEnvelope, to: ProviderState(provider: ProviderCatalog.gemini))
        XCTAssertEqual(freshFailed.status, .failed)
        XCTAssertNil(freshFailed.envelope)
        XCTAssertFalse(freshFailed.isStale)

        // 5. 删除账号后刷新：用未配置 envelope 替换旧值，不残留原账号 5h/7d 用量
        let cleared = ProviderReducer.apply(unconfigured, to: state)
        XCTAssertEqual(cleared.status, .warning)
        XCTAssertNil(cleared.accountLabel)
        XCTAssertTrue(cleared.windows.isEmpty)
        XCTAssertNil(Tension.mostTense(in: [cleared], now: now))
    }

    func testAuthFailureAfterUnconfiguredOrEmptyQuotaBecomesFailed() {
        let now = Date()

        // 1. 未配置账号成功 envelope（0 窗口、无指标）后遇到 HTTP 401 -> 必须进入 .failed，而不是 .stale
        let unconfigured = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"]
            ),
            finishedAt: now
        )
        let auth401 = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: nil),
                windows: [],
                error: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"
            ),
            failure: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号",
            finishedAt: now.addingTimeInterval(30)
        )

        var state = ProviderState(provider: ProviderCatalog.gemini)
        state = ProviderReducer.apply(unconfigured, to: state)
        XCTAssertEqual(state.status, .warning)
        XCTAssertFalse(state.hasDisplayableUsage)

        state = ProviderReducer.apply(auth401, to: state)
        XCTAssertEqual(state.status, .failed)
        XCTAssertFalse(state.isStale)
        XCTAssertNil(state.envelope)
        XCTAssertNil(state.lastDataAt)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertEqual(state.failureReason, auth401.failure)
        XCTAssertNil(Tension.mostTense(in: [state], now: now))

        // 2. 已配置账号但返回空配额（0 窗口、无指标）后遇到 HTTP 403 -> 也必须进入 .failed
        let emptyQuota = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: "free"),
                windows: [],
                warnings: ["未返回任何配额窗口"]
            ),
            finishedAt: now
        )
        let auth403 = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: nil),
                windows: [],
                error: "Gemini 账号凭据无权限（HTTP 403），请在配置中重新提供账号"
            ),
            failure: "Gemini 账号凭据无权限（HTTP 403），请在配置中重新提供账号",
            finishedAt: now.addingTimeInterval(60)
        )

        var emptyState = ProviderReducer.apply(emptyQuota, to: ProviderState(provider: ProviderCatalog.gemini))
        XCTAssertEqual(emptyState.status, .warning)
        XCTAssertFalse(emptyState.hasDisplayableUsage)

        emptyState = ProviderReducer.apply(auth403, to: emptyState)
        XCTAssertEqual(emptyState.status, .failed)
        XCTAssertFalse(emptyState.isStale)
        XCTAssertNil(emptyState.envelope)
        XCTAssertNil(emptyState.lastDataAt)
        XCTAssertTrue(emptyState.windows.isEmpty)
        XCTAssertEqual(emptyState.failureReason, auth403.failure)
    }
}
