import Foundation
import XCTest
@testable import UsageLensKit

final class GeminiAccountTests: XCTestCase {
    private let fakeEmail = "user@gmail.com"
    private let fakeToken = "ya29.a0AfB_byTestSecretToken1234567890abcdef"
    private let fakeRefresh = "1//0eTestRefreshToken1234567890abcdef"
    private let fakeRefreshed = "ya29.a0AfB_byRefreshedToken9876543210fedcba"

    private func futureISO(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(seconds))
    }

    private func jsonResponse(_ obj: [String: Any], url: URL, status: Int = 200) -> Result<NativeHTTPResponse, Error> {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        return .success(NativeHTTPResponse(statusCode: status, finalURL: url, body: body))
    }

    private func okQuotaResponse() -> Result<NativeHTTPResponse, Error> {
        jsonResponse([
            "buckets": [
                ["modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": futureISO(3600), "windowDuration": "5h"],
                ["modelId": "gemini-2.5-pro", "remainingFraction": 0.60, "resetTime": futureISO(4 * 86_400), "windowDuration": "7d"],
            ],
        ], url: GeminiNativeProbe.retrieveQuotaURL)
    }

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

        try GeminiAccountStore.delete(storage: storage)
        XCTAssertFalse(GeminiAccountStore.hasSavedAccount(storage: storage))
        XCTAssertNil(GeminiAccountStore.savedAccountEmail(storage: storage))
        XCTAssertNil(GeminiAccountStore.load(storage: storage))
    }

    func testGeminiAccountValidationSuccessAndFailureNativeSwift() async {
        let transport = MockNativeHTTPTransport { req in
            let auth = req.headers["Authorization"] ?? ""
            if auth != "Bearer ya29.good_token_12345" {
                return NativeHTTPResponse(statusCode: 401, finalURL: req.url, body: Data("{}".utf8))
            }
            if req.url == GeminiNativeProbe.loadCodeAssistURL {
                let body = try JSONSerialization.data(withJSONObject: [
                    "cloudaicompanionProject": "projects/demo",
                    "currentTier": ["id": "pro"],
                ])
                return NativeHTTPResponse(statusCode: 200, finalURL: req.url, body: body)
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "buckets": [
                    ["windowDuration": "5h", "remainingFraction": 0.75, "resetTime": self.futureISO(3600)],
                    ["windowDuration": "7d", "remainingFraction": 0.60, "resetTime": self.futureISO(4 * 86_400)],
                ],
            ])
            return NativeHTTPResponse(statusCode: 200, finalURL: req.url, body: body)
        }

        let runner = ProbeRunner(
            timeout: 5,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { ["HOME": "/tmp/empty-home-\(UUID().uuidString)"] },
            transport: transport
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

    func testGeminiProjectPrecedenceTrimmingAndLoadQuotaSemantics() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-gemini-proj-\(UUID().uuidString)", isDirectory: true)
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let cases: [(String, [String: String], String)] = [
            (
                "gemini_project_id_wins",
                [
                    "GEMINI_PROJECT_ID": "  proj-gemini-id  ",
                    "GOOGLE_CLOUD_PROJECT": "proj-gcp",
                    "GOOGLE_CLOUD_PROJECT_ID": "proj-gcp-id",
                ],
                "proj-gemini-id"
            ),
            (
                "google_cloud_project_wins_over_id",
                [
                    "GEMINI_PROJECT_ID": "   ",
                    "GOOGLE_CLOUD_PROJECT": "  proj-gcp  ",
                    "GOOGLE_CLOUD_PROJECT_ID": "proj-gcp-id",
                ],
                "proj-gcp"
            ),
            (
                "google_cloud_project_id_fallback",
                [
                    "GEMINI_PROJECT_ID": "",
                    "GOOGLE_CLOUD_PROJECT": " \t ",
                    "GOOGLE_CLOUD_PROJECT_ID": "  proj-gcp-id  ",
                ],
                "proj-gcp-id"
            ),
        ]

        // 1. Manual OAuth
        for (name, projEnv, expected) in cases {
            let transport = MockNativeHTTPTransport(responses: [
                jsonResponse(["cloudaicompanionProject": "proj-server-other", "currentTier": ["id": "standard"]], url: GeminiNativeProbe.loadCodeAssistURL),
                okQuotaResponse(),
            ])
            var env = projEnv
            env["HOME"] = tempHome.path
            env["GEMINI_ACCOUNT_EMAIL"] = fakeEmail
            env["GEMINI_ACCESS_TOKEN"] = fakeToken
            let report = await GeminiNativeProbe(transport: transport).run(environment: env)
            XCTAssertNil(report.failure, "\(name): \(report.failure ?? "")")
            XCTAssertEqual(transport.calls.count, 2)
            let loadBody = try JSONSerialization.jsonObject(with: XCTUnwrap(transport.calls[0].body)) as? [String: Any]
            let meta = loadBody?["metadata"] as? [String: Any]
            XCTAssertEqual(loadBody?["cloudaicompanionProject"] as? String, expected, name)
            XCTAssertEqual(meta?["duetProject"] as? String, expected, name)
            let quotaBody = try JSONSerialization.jsonObject(with: XCTUnwrap(transport.calls[1].body)) as? [String: Any]
            XCTAssertEqual(quotaBody?["project"] as? String, expected, "explicit project must not be replaced: \(name)")
        }

        // 2. Local OAuth (~/.gemini/oauth_creds.json)
        let localCreds: [String: Any] = [
            "access_token": "ya29.localWorkspaceToken1234567890",
            "expiry_date": Int((Date().timeIntervalSince1970 + 3600) * 1000),
        ]
        try JSONSerialization.data(withJSONObject: localCreds)
            .write(to: geminiDir.appendingPathComponent("oauth_creds.json"))
        try #"{"active":"workspace@example.com","old":[]}"#
            .write(to: geminiDir.appendingPathComponent("google_accounts.json"), atomically: true, encoding: .utf8)

        let transportLocal = MockNativeHTTPTransport(responses: [
            jsonResponse(["cloudaicompanionProject": "proj-server-ignored", "currentTier": ["id": "pro"]], url: GeminiNativeProbe.loadCodeAssistURL),
            okQuotaResponse(),
        ])
        let localReport = await GeminiNativeProbe(transport: transportLocal).run(environment: [
            "HOME": tempHome.path,
            "GOOGLE_CLOUD_PROJECT": "ws-proj-local",
        ])
        XCTAssertNil(localReport.failure)
        XCTAssertEqual(localReport.envelope?.account?.label, "workspace@example.com")
        let localLoad = try JSONSerialization.jsonObject(with: XCTUnwrap(transportLocal.calls[0].body)) as? [String: Any]
        XCTAssertEqual(localLoad?["cloudaicompanionProject"] as? String, "ws-proj-local")
        let localQuota = try JSONSerialization.jsonObject(with: XCTUnwrap(transportLocal.calls[1].body)) as? [String: Any]
        XCTAssertEqual(localQuota?["project"] as? String, "ws-proj-local")
    }

    func testGeminiNumericProjectNumberRejectedWithoutEchoingInput() async {
        let cases: [([String: String], String)] = [
            (["GOOGLE_CLOUD_PROJECT": "123456789012"], "123456789012"),
            (["GOOGLE_CLOUD_PROJECT_ID": "  987654321098  "], "987654321098"),
            (["GEMINI_PROJECT_ID": "projects/555666777888"], "555666777888"),
            (["GEMINI_PROJECT_ID": "444333222111", "GOOGLE_CLOUD_PROJECT": "valid-proj"], "444333222111"),
        ]
        for (projEnv, forbidden) in cases {
            let transport = MockNativeHTTPTransport()
            var env = projEnv
            env["GEMINI_ACCOUNT_EMAIL"] = fakeEmail
            env["GEMINI_ACCESS_TOKEN"] = fakeToken
            let report = await GeminiNativeProbe(transport: transport).run(environment: env)
            XCTAssertTrue(transport.calls.isEmpty, "纯数字项目编号不得发起任何网络请求")
            XCTAssertTrue(report.failure?.contains("项目编号") ?? false)
            XCTAssertFalse(report.failure?.contains(forbidden) ?? true, "绝不可回显用户输入的项目编号")
        }
    }

    func testGeminiNoProjectDiscoveryMissingProject401Refresh403DenialAndAPIKeyIsolation() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-gemini-flow-\(UUID().uuidString)", isDirectory: true)
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        // 1. API-key-only / project-only without OAuth -> zero network calls, no account inferred
        for env in [
            ["HOME": tempHome.path, "GEMINI_API_KEY": "AIzaSyGeminiOnly1234567890abcdef"],
            ["HOME": tempHome.path, "GOOGLE_API_KEY": "AIzaSyGoogleOnly1234567890abcdef"],
            [
                "HOME": tempHome.path,
                "GEMINI_API_KEY": "AIzaSyGeminiOnly1234567890abcdef",
                "GOOGLE_API_KEY": "AIzaSyGoogleOnly1234567890abcdef",
                "GOOGLE_CLOUD_PROJECT": "ws-no-oauth",
            ],
        ] {
            let transport = MockNativeHTTPTransport()
            let report = await GeminiNativeProbe(transport: transport).run(environment: env)
            XCTAssertTrue(transport.calls.isEmpty)
            XCTAssertNil(report.failure)
            XCTAssertNil(report.envelope?.account?.label)
            XCTAssertTrue(report.warnings.contains { $0.contains("提供 Gemini 账号") })
        }

        // 2. No configured project + server omits cloudaicompanionProject -> honest guidance, zero quota call
        let transportMissing = MockNativeHTTPTransport(responses: [
            jsonResponse(["currentTier": ["id": "standard"]], url: GeminiNativeProbe.loadCodeAssistURL),
        ])
        let missingReport = await GeminiNativeProbe(transport: transportMissing).run(environment: [
            "HOME": tempHome.path,
            "GEMINI_ACCOUNT_EMAIL": fakeEmail,
            "GEMINI_ACCESS_TOKEN": fakeToken,
        ])
        XCTAssertEqual(transportMissing.calls.count, 1)
        let loadSent = try JSONSerialization.jsonObject(with: XCTUnwrap(transportMissing.calls[0].body)) as? [String: Any]
        XCTAssertNil(loadSent?["cloudaicompanionProject"])
        XCTAssertTrue(missingReport.failure?.contains("GOOGLE_CLOUD_PROJECT") ?? false)
        XCTAssertTrue(missingReport.failure?.contains("IAM") ?? false)

        // 3. Local OAuth + explicit GOOGLE_CLOUD_PROJECT: bounded single 401 refresh + 403 denial without replacement
        let credsFile = geminiDir.appendingPathComponent("oauth_creds.json")
        let credsData = try JSONSerialization.data(withJSONObject: [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "client_id": "synthetic-client.apps.googleusercontent.com",
            "expiry_date": Int((Date().timeIntervalSince1970 + 3600) * 1000),
        ])
        try credsData.write(to: credsFile)
        try #"{"active":"ws.local@example.com","old":[]}"#
            .write(to: geminiDir.appendingPathComponent("google_accounts.json"), atomically: true, encoding: .utf8)

        let transport401 = MockNativeHTTPTransport(responses: [
            jsonResponse([:], url: GeminiNativeProbe.loadCodeAssistURL, status: 401),
            jsonResponse(["access_token": fakeRefreshed], url: GeminiNativeProbe.oauthTokenURL),
            jsonResponse(["cloudaicompanionProject": "server-other"], url: GeminiNativeProbe.loadCodeAssistURL),
            jsonResponse([:], url: GeminiNativeProbe.retrieveQuotaURL, status: 401),
        ])
        let report401 = await GeminiNativeProbe(transport: transport401).run(environment: [
            "HOME": tempHome.path,
            "GOOGLE_CLOUD_PROJECT": "ws-proj-explicit",
        ])
        let oauthCount = transport401.calls.filter { $0.url == GeminiNativeProbe.oauthTokenURL }.count
        XCTAssertEqual(oauthCount, 1, "单次执行最多刷新一次")
        XCTAssertTrue(report401.failure?.contains("HTTP 401") ?? false)
        XCTAssertEqual(try Data(contentsOf: credsFile), credsData, "绝不修改本地凭据文件")

        let transport403 = MockNativeHTTPTransport(responses: [
            jsonResponse(["cloudaicompanionProject": "server-other"], url: GeminiNativeProbe.loadCodeAssistURL),
            jsonResponse(["error": "permission_denied"], url: GeminiNativeProbe.retrieveQuotaURL, status: 403),
        ])
        let report403 = await GeminiNativeProbe(transport: transport403).run(environment: [
            "HOME": tempHome.path,
            "GOOGLE_CLOUD_PROJECT": "ws-proj-explicit",
        ])
        XCTAssertEqual(transport403.calls.count, 2)
        XCTAssertTrue(report403.failure?.contains("HTTP 403") ?? false)
        XCTAssertTrue(report403.failure?.contains("IAM") ?? false)
        XCTAssertFalse(report403.failure?.contains("ws-proj-explicit") ?? true)
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

        let apiKey = SecretRedactor.redact("failed AIzaSySyntheticKey123456789 end")
        XCTAssertTrue(apiKey.contains("***"))
        XCTAssertFalse(apiKey.contains("AIzaSy"))
        XCTAssertTrue(apiKey.contains("end"))
    }

    func testDetectLocalCLIAuthAndCredentialSourcePriority() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-gemini-local-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let storage = InMemoryGeminiKeychainStorage()

        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))
        XCTAssertEqual(GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome), .unconfigured)

        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")
        try "{bad json".write(to: credsURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))

        try #"{"access_token":"   ","refresh_token":""}"#.write(to: credsURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GeminiAccountStore.detectLocalCLIAuth(homeDirectory: tempHome))

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

        try GeminiAccountStore.save(email: "manual@gmail.com", accessToken: "ya29.manual_token", storage: storage)
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .manualKeychain(email: "manual@gmail.com")
        )

        try GeminiAccountStore.delete(storage: storage)
        XCTAssertEqual(
            GeminiAccountStore.credentialSource(storage: storage, homeDirectory: tempHome),
            .localCLI(email: "active.local@gmail.com")
        )
    }

    func testGeminiStateTransitionsAndMenuBarTension() {
        let now = Date()
        var state = ProviderState(provider: ProviderCatalog.gemini)

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

        let freshFailed = ProviderReducer.apply(expiredWithEmptyEnvelope, to: ProviderState(provider: ProviderCatalog.gemini))
        XCTAssertEqual(freshFailed.status, .failed)
        XCTAssertNil(freshFailed.envelope)
        XCTAssertFalse(freshFailed.isStale)

        let cleared = ProviderReducer.apply(unconfigured, to: state)
        XCTAssertEqual(cleared.status, .warning)
        XCTAssertNil(cleared.accountLabel)
        XCTAssertTrue(cleared.windows.isEmpty)
        XCTAssertNil(Tension.mostTense(in: [cleared], now: now))
    }

    func testAuthFailureAfterUnconfiguredOrEmptyQuotaBecomesFailed() {
        let now = Date()
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
    }

    func testGeminiNativeDelayedMultiStepRefreshAndBoundedDeadline() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-gemini-delay-\(UUID().uuidString)", isDirectory: true)
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let credsJSON = """
        {
          "access_token": "ya29.expired_local_token_12345",
          "refresh_token": "1//synthetic_refresh_token_12345",
          "client_id": "synthetic-client-id.apps.googleusercontent.com",
          "expiry_date": 1000000000000
        }
        """
        try credsJSON.write(to: geminiDir.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
        try #"{"active":"delayed.local@gmail.com","old":[]}"#
            .write(to: geminiDir.appendingPathComponent("google_accounts.json"), atomically: true, encoding: .utf8)

        let delayedTransport = MockNativeHTTPTransport { req in
            try await Task.sleep(nanoseconds: 120_000_000)
            if req.url == GeminiNativeProbe.oauthTokenURL {
                let body = try JSONSerialization.data(withJSONObject: ["access_token": "ya29.refreshed_delayed_12345", "expires_in": 3600])
                return NativeHTTPResponse(statusCode: 200, finalURL: req.url, body: body)
            }
            if req.url == GeminiNativeProbe.loadCodeAssistURL {
                let body = try JSONSerialization.data(withJSONObject: ["cloudaicompanionProject": "proj-delayed", "currentTier": ["id": "pro"]])
                return NativeHTTPResponse(statusCode: 200, finalURL: req.url, body: body)
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "buckets": [
                    ["windowDuration": "5h", "remainingFraction": 0.75, "resetTime": self.futureISO(3600)],
                    ["windowDuration": "7d", "remainingFraction": 0.60, "resetTime": self.futureISO(4 * 86_400)],
                ],
            ])
            return NativeHTTPResponse(statusCode: 200, finalURL: req.url, body: body)
        }

        let defaultRunner = ProbeRunner(
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { ["HOME": tempHome.path] },
            transport: delayedTransport
        )
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.codex), 6)
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.deepseek), 6)
        XCTAssertEqual(defaultRunner.effectiveTimeout(for: ProviderCatalog.gemini), 15)

        let report = await defaultRunner.report(for: ProviderCatalog.gemini)
        XCTAssertNil(report.failure, report.failure ?? "nil")
        XCTAssertEqual(report.envelope?.account?.label, "delayed.local@gmail.com")
        XCTAssertEqual(report.envelope?.account?.plan, "pro")
        XCTAssertEqual(report.envelope?.windows.count, 2)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "5h" })?.usedPercent, 25)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "7d" })?.usedPercent, 40)

        // Bounded timeout enforcement
        let boundedRunner = ProbeRunner(
            providerTimeouts: [ProviderCatalog.gemini.id: 0.15],
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { ["HOME": tempHome.path] },
            transport: delayedTransport
        )
        let timedOut = await boundedRunner.report(for: ProviderCatalog.gemini)
        XCTAssertNil(timedOut.envelope)
        XCTAssertTrue(timedOut.failure?.contains("探针超时") ?? false, timedOut.failure ?? "nil")
        XCTAssertLessThan(timedOut.duration, 1.0)
    }
}
