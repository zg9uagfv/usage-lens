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

        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.syntheticSignature_12345"
        let redactedJWT = SecretRedactor.redact("token \(jwt) failed")
        XCTAssertTrue(redactedJWT.contains("***"))
        XCTAssertFalse(redactedJWT.contains("eyJhbGciOiJSUzI1NiJ9"))
        XCTAssertTrue(redactedJWT.contains("failed"))
    }

    func testDetectLocalCLIAuthAndCredentialSourcePriority() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-gemini-local-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let storage = InMemoryGeminiKeychainStorage()

        // 1. 无本机文件且无钥匙串 -> unconfigured
        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))
        XCTAssertEqual(GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome), .unconfigured)

        // 2. 写入畸形 JSON -> nil
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")
        try "{bad json".write(to: credsURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))

        // 3. 空令牌 -> nil
        try #"{"access_token":"   ","refresh_token":""}"#.write(to: credsURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))

        // 4. 有效本机令牌 + id_token JWT email 回退
        let jwtPayloadData = Data(#"{"email":"jwt.user@gmail.com"}"#.utf8)
        let jwtPayloadB64 = jwtPayloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fakeIDToken = "eyJhbGciOiJSUzI1NiJ9.\(jwtPayloadB64).fakesig"
        let credsWithJWT = """
        {"access_token":"ya29.local_test_token_only","id_token":"\(fakeIDToken)"}
        """
        try credsWithJWT.write(to: credsURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome),
            GeminiLocalAuthInfo(email: "jwt.user@gmail.com")
        )
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .localCLI(email: "jwt.user@gmail.com")
        )

        // 5. google_accounts.json 的 active 优先于 id_token
        let accountsURL = geminiDir.appendingPathComponent("google_accounts.json")
        try #"{"active":"active.local@gmail.com","old":[]}"#.write(to: accountsURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome),
            GeminiLocalAuthInfo(email: "active.local@gmail.com")
        )
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .localCLI(email: "active.local@gmail.com")
        )

        // 6. 保存手动钥匙串账号 -> 最高优先级 (.manualKeychain)
        try GeminiAccountStore.save(email: "manual@gmail.com", accessToken: "ya29.manual_token", storage: storage)
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .manualKeychain(email: "manual@gmail.com")
        )

        // 7. 删除手动钥匙串账号 -> 自动回落到 .localCLI
        try GeminiAccountStore.delete(storage: storage)
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .localCLI(email: "active.local@gmail.com")
        )
    }

    func testValidationMessagePassesDisableLocalAuthEnv() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".cache/gemini-disable-local-auth-tests", isDirectory: true)
        let probes = root.appendingPathComponent("probes", isDirectory: true)
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)

        let script = probes.appendingPathComponent("gemini.py")
        let scriptText = """
        import json, os, sys
        disabled = os.environ.get("GEMINI_DISABLE_LOCAL_AUTH")
        if disabled != "1":
            print(json.dumps({"schema": "usage-lens/probe@1", "provider": "gemini", "windows": [], "error": "missing GEMINI_DISABLE_LOCAL_AUTH"}))
            sys.exit(1)
        print(json.dumps({
            "schema": "usage-lens/probe@1",
            "provider": "gemini",
            "account": {"label": os.environ.get("GEMINI_ACCOUNT_EMAIL"), "plan": "pro"},
            "windows": [{"id": "5h", "label": "5 小时", "used_percent": 10, "window_seconds": 18000, "basis": "server"}],
            "warnings": [],
            "error": None
        }))
        """
        try scriptText.write(to: script, atomically: true, encoding: .utf8)

        let runner = ProbeRunner(
            root: root,
            timeout: 5,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )
        let msg = await GeminiAccountStore.validationMessage(
            email: "user@gmail.com",
            accessToken: "ya29.candidate_token",
            runner: runner
        )
        XCTAssertNil(msg)
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

    func testGeminiDelayedMultiStepRefreshSucceedsWithinDefaultBudgetAndEnforcesBoundedDeadline() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "usage-lens-gemini-timeout-\(UUID().uuidString)",
            isDirectory: true
        )
        let probesDir = tempRoot.appendingPathComponent("probes", isDirectory: true)
        let tempHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try fm.createDirectory(at: probesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let realGeminiProbe = repoRoot.appendingPathComponent("probes/gemini.py")
        XCTAssertTrue(fm.fileExists(atPath: realGeminiProbe.path), "找不到真实 probes/gemini.py：\(realGeminiProbe.path)")

        let credsJSON = """
        {
          "access_token": "ya29.expired_local_token_12345",
          "refresh_token": "1//synthetic_refresh_token_12345",
          "client_id": "synthetic-client-id.apps.googleusercontent.com",
          "expiry_date": 1000000000000
        }
        """
        try credsJSON.write(
            to: geminiDir.appendingPathComponent("oauth_creds.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"active":"delayed.local@gmail.com","old":[]}"#.write(
            to: geminiDir.appendingPathComponent("google_accounts.json"),
            atomically: true,
            encoding: .utf8
        )

        let wrapperScript = """
        import importlib.util, json, sys, time

        spec = importlib.util.spec_from_file_location("real_gemini_probe", \(String(reflecting: realGeminiProbe.path)))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class _DelayedResponse:
            def __init__(self, body, final_url):
                self._body = body
                self._final_url = final_url
                self.headers = {"Content-Length": str(len(body))}
            def geturl(self):
                return self._final_url
            def read(self, amount=-1):
                return self._body if amount is None or amount < 0 else self._body[:amount]
            def __enter__(self):
                return self
            def __exit__(self, *exc_info):
                return False

        class _DelayedOpener:
            def open(self, request, timeout=None):
                assert timeout is not None and timeout <= 3.0
                time.sleep(2.15)
                url = request.full_url
                if url == module.OAUTH_TOKEN_URL:
                    body = json.dumps({"access_token": "ya29.refreshed_delayed_token_12345", "expires_in": 3600}).encode("utf-8")
                    return _DelayedResponse(body, url)
                if url == module.LOAD_CODE_ASSIST_URL:
                    body = json.dumps({"cloudaicompanionProject": "proj-delayed", "currentTier": {"id": "pro"}}).encode("utf-8")
                    return _DelayedResponse(body, url)
                if url == module.RETRIEVE_QUOTA_URL:
                    body = json.dumps({
                        "buckets": [
                            {"windowDuration": "5h", "remainingFraction": 0.75, "resetTime": "2099-01-01T05:00:00Z"},
                            {"windowDuration": "7d", "remainingFraction": 0.60, "resetTime": "2099-01-07T00:00:00Z"},
                        ]
                    }).encode("utf-8")
                    return _DelayedResponse(body, url)
                raise AssertionError("unexpected url: " + url)

        module._OPENER = _DelayedOpener()
        sys.exit(module.main(["gemini.py"]))
        """
        try wrapperScript.write(
            to: probesDir.appendingPathComponent("gemini.py"),
            atomically: true,
            encoding: .utf8
        )

        // 1. 默认 ProbeRunner：Gemini 享有 15s 有界预算，其他探针保持 6s 默认。
        let defaultRunner = ProbeRunner(
            root: tempRoot,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.codex), 6)
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.deepseek), 6)
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.gemini), 15)

        let report = await defaultRunner.report(
            for: ProviderCatalog.gemini,
            environmentOverrides: ["HOME": tempHome.path]
        )
        XCTAssertNil(report.failure, report.failure ?? "nil")
        XCTAssertGreaterThanOrEqual(report.duration, 6.0, "3 步延迟序列总时长应超过 6s")
        XCTAssertEqual(report.envelope?.account?.label, "delayed.local@gmail.com")
        XCTAssertEqual(report.envelope?.account?.plan, "pro")
        XCTAssertEqual(report.envelope?.windows.count, 2)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "5h" })?.usedPercent, 25)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "7d" })?.usedPercent, 40)

        // 2. 仍严格执行有界超时，并在失败文案中报告实际截止时间。
        let boundedRunner = ProbeRunner(
            root: tempRoot,
            providerTimeouts: [ProviderCatalog.gemini.id: 2],
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )
        let timedOut = await boundedRunner.report(
            for: ProviderCatalog.gemini,
            environmentOverrides: ["HOME": tempHome.path]
        )
        XCTAssertNil(timedOut.envelope)
        XCTAssertEqual(timedOut.failure, "探针超时（>2s）")
        XCTAssertLessThan(timedOut.duration, 5.0)
    }
}
