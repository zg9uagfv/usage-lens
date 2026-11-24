import Foundation
import XCTest
@testable import UsageLensKit

// MARK: - 测试用 Mock Transport 与 Mock Keychain

final class MockNativeHTTPTransport: NativeHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<NativeHTTPResponse, Error>]
    private var handler: ((NativeHTTPRequest) async throws -> NativeHTTPResponse)?
    private var recordedRequests: [NativeHTTPRequest] = []

    init(responses: [Result<NativeHTTPResponse, Error>] = []) {
        self.responses = responses
    }

    init(handler: @escaping (NativeHTTPRequest) async throws -> NativeHTTPResponse) {
        self.responses = []
        self.handler = handler
    }

    var calls: [NativeHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private func dequeueNext(_ request: NativeHTTPRequest) -> (((NativeHTTPRequest) async throws -> NativeHTTPResponse)?, Result<NativeHTTPResponse, Error>?) {
        lock.withLock {
            recordedRequests.append(request)
            let customHandler = handler
            let nextResult = responses.isEmpty ? nil : responses.removeFirst()
            return (customHandler, nextResult)
        }
    }

    func send(_ request: NativeHTTPRequest) async throws -> NativeHTTPResponse {
        let (customHandler, nextResult) = dequeueNext(request)

        if let customHandler {
            return try await customHandler(request)
        }
        guard let nextResult else {
            throw NativeHTTPError.network("unexpected request: \(request.url.absoluteString)")
        }
        return try nextResult.get()
    }
}

final class MockAgyKeychainReader: AgyKeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: AgyKeychainReadResult
    private var recordedQueries: [(service: String, account: String)] = []

    init(result: AgyKeychainReadResult) {
        self.result = result
    }

    var queries: [(service: String, account: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedQueries
    }

    func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult {
        lock.lock()
        recordedQueries.append((service, account))
        lock.unlock()
        return result
    }
}

final class InMemoryAgyKeychainStore: AgyKeychainReading, AgyKeychainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayload: String?
    private let forcedWriteResult: AgyKeychainWriteResult?
    private var recordedReads: [(service: String, account: String)] = []
    private var recordedWrites: [(service: String, account: String, payload: String)] = []

    init(initialPayload: String?, forcedWriteResult: AgyKeychainWriteResult? = nil) {
        self.storedPayload = initialPayload
        self.forcedWriteResult = forcedWriteResult
    }

    var currentPayload: String? {
        lock.withLock { storedPayload }
    }

    var readQueries: [(service: String, account: String)] {
        lock.withLock { recordedReads }
    }

    var writeCalls: [(service: String, account: String, payload: String)] {
        lock.withLock { recordedWrites }
    }

    func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult {
        lock.withLock {
            recordedReads.append((service, account))
            guard let storedPayload else { return .missing }
            return .payload(storedPayload)
        }
    }

    func updateGenericPassword(service: String, account: String, payload: String) -> AgyKeychainWriteResult {
        lock.withLock {
            recordedWrites.append((service, account, payload))
            if let forcedWriteResult {
                return forcedWriteResult
            }
            guard SystemAgyKeychainReader.isAllowedTuple(service: service, account: account) else {
                return .rejected
            }
            guard storedPayload != nil else {
                return .missing
            }
            storedPayload = payload
            return .updated
        }
    }
}

// MARK: - AGY 原生探针与环境边界测试

final class AgyProviderTests: XCTestCase {
    private let fakeEmail = "agy.user@example.com"
    private let fakeToken = "ya29.a0AfB_bySyntheticAgyToken1234567890abcdef"
    private let fakeRefresh = "1//0eSyntheticAgyRefreshToken1234567890abcdef"
    private let fakeNewToken = "ya29.a0AfB_bySyntheticRefreshedToken9876543210"
    private let fakeClientID = "123456789-synthetic.apps.googleusercontent.com"

    private func futureISO(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(seconds))
    }

    private func pastISO(_ seconds: TimeInterval) -> String {
        futureISO(-seconds)
    }

    private func makeKeyringPayload(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiry: String? = nil,
        email: String? = nil,
        clientID: String? = nil,
        wrapBase64: Bool = true
    ) -> String {
        var obj: [String: Any] = [
            "token": [
                "access_token": accessToken ?? fakeToken,
                "token_type": "Bearer",
                "refresh_token": refreshToken ?? fakeRefresh,
                "expiry": expiry ?? futureISO(3600),
                "expires_in": 3599,
            ],
            "auth_method": "oauth",
            "id_token_email": email ?? fakeEmail,
            "writer_id": "test-writer",
        ]
        if let clientID { obj["client_id"] = clientID }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        if wrapBase64 {
            return "go-keyring-base64:\(data.base64EncodedString())"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonResponse(_ obj: [String: Any], url: URL, status: Int = 200) -> Result<NativeHTTPResponse, Error> {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        return .success(NativeHTTPResponse(statusCode: status, finalURL: url, body: body))
    }

    func testProviderCatalogAgyMetadataAndDefaultOrdering() {
        let agy = ProviderCatalog.agy
        XCTAssertEqual(agy.id, "agy")
        XCTAssertEqual(agy.displayName, "AGY")
        XCTAssertEqual(agy.probeRelativePath, "probes/agy.py")
        XCTAssertFalse(agy.requiresAPIKey)
        XCTAssertFalse(agy.requiresAccount)
        XCTAssertFalse(agy.requiresCredentials)

        let availableIDs = ProviderCatalog.available.map(\.id)
        XCTAssertEqual(availableIDs, ["codex", "agy", "gemini", "opencode", "deepseek"])
        XCTAssertEqual(ProviderCatalog.defaultActiveIDs, ["codex", "agy", "gemini", "opencode"])
        XCTAssertEqual(ProviderCatalog.provider(id: "agy"), agy)
    }

    func testProbeRunnerAgyTimeoutBudget() {
        let runner = ProbeRunner(
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.agy), 15)
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.gemini), 15)
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.codex), 6)
    }

    func testProbeRunnerEnforcesFinalEnvironmentBoundaryAcrossAllProvidersUnknownAndNil() {
        let syntheticParentVars: [String: String] = [
            "HOME": "/tmp/synthetic-home",
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "GEMINI_ACCESS_TOKEN": "ya29.parent_gemini_marker_only",
            "GEMINI_ACCOUNT_EMAIL": "parent.gemini@example.com",
            "GEMINI_PROJECT_ID": "parent-gemini-proj",
            "GEMINI_OAUTH_CLIENT_ID": "parent-gemini-client-marker",
            "GEMINI_OAUTH_CLIENT_SECRET": "parent-gemini-secret-marker",
            "GEMINI_API_KEY": "AIzaSyParentGeminiApiKeyMarker1234",
            "GEMINI_FUTURE_SYNTHETIC": "future-gemini-marker",
            "AGY_ACCESS_TOKEN": "ya29.parent_agy_marker_only",
            "AGY_PROJECT_ID": "parent-agy-proj",
            "AGY_OAUTH_CLIENT_ID": "parent-agy-client-marker",
            "AGY_OAUTH_CLIENT_SECRET": "parent-agy-secret-marker",
            "AGY_FUTURE_SYNTHETIC": "future-agy-marker",
            "CODEX_ACCESS_TOKEN": "sk-parent-codex-marker-only",
            "DEEPSEEK_API_KEY": "sk-parent-deepseek-marker-1234",
            "GOOGLE_API_KEY": "AIzaSyParentGoogleApiKeyMarker5678",
            "GOOGLE_CLOUD_PROJECT": "parent-gcp-proj",
            "GOOGLE_CLOUD_PROJECT_ID": "parent-gcp-proj-id",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/synthetic-adc-marker.json",
            "GOOGLE_CREDENTIALS": "synthetic-google-creds-marker",
            "CLOUDSDK_AUTH_ACCESS_TOKEN": "ya29.parent_cloudsdk_marker_only",
            "GOOGLE_NON_CREDENTIAL_SYNTHETIC": "harmless-google-flag",
        ]

        let conflictingOverrides: [String: String] = [
            "GEMINI_OAUTH_CLIENT_SECRET": "override-gemini-secret-marker",
            "GEMINI_API_KEY": "AIzaSyOverrideGeminiApiKeyMarker12",
            "GEMINI_FUTURE_SYNTHETIC": "override-future-gemini-marker",
            "AGY_ACCESS_TOKEN": "ya29.override_agy_marker_only",
            "AGY_FUTURE_SYNTHETIC": "override-future-agy-marker",
            "CODEX_ACCESS_TOKEN": "sk-override-codex-marker-only",
            "DEEPSEEK_API_KEY": "sk-override-deepseek-marker-5678",
            "GOOGLE_API_KEY": "AIzaSyOverrideGoogleApiKeyMarker34",
            "GOOGLE_CLOUD_PROJECT": "override-gcp-proj",
            "GOOGLE_CLOUD_PROJECT_ID": "override-gcp-proj-id",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/override-adc-marker.json",
            "GOOGLE_CREDENTIALS": "override-google-creds-marker",
            "CLOUDSDK_AUTH_ACCESS_TOKEN": "ya29.override_cloudsdk_marker_only",
        ]

        let runner = ProbeRunner(
            deepSeekAPIKeyLoader: { "sk-keychain-deepseek-marker-9999" },
            geminiAccountLoader: {
                GeminiAccount(
                    email: "keychain.gemini@example.com",
                    accessToken: "ya29.keychain_gemini_marker_only",
                    projectID: "keychain-gemini-proj"
                )
            }
        )

        let unknownProvider = Provider(id: "unknown-provider", displayName: "Unknown", probeRelativePath: "probes/unknown.py")
        let targets: [Provider?] = ProviderCatalog.all.map { Optional($0) } + [unknownProvider, nil]

        for provider in targets {
            let pid = provider?.id
            let isGemini = pid == ProviderCatalog.gemini.id
            let isAgy = pid == ProviderCatalog.agy.id
            let isDeepSeek = pid == ProviderCatalog.deepseek.id
            let isCodex = pid == ProviderCatalog.codex.id

            let env = runner.buildEnvironment(
                baseEnvironment: syntheticParentVars,
                for: provider,
                overrides: conflictingOverrides
            )

            XCTAssertEqual(env["GEMINI_ACCESS_TOKEN"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GEMINI_ACCOUNT_EMAIL"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GEMINI_PROJECT_ID"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GEMINI_OAUTH_CLIENT_ID"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GEMINI_OAUTH_CLIENT_SECRET"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GEMINI_FUTURE_SYNTHETIC"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertNil(env["GEMINI_API_KEY"], "GEMINI_API_KEY must never pass to \(pid ?? "nil")")

            XCTAssertEqual(env["AGY_ACCESS_TOKEN"] != nil, isAgy, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["AGY_PROJECT_ID"] != nil, isAgy, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["AGY_OAUTH_CLIENT_ID"] != nil, isAgy, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["AGY_OAUTH_CLIENT_SECRET"] != nil, isAgy, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["AGY_FUTURE_SYNTHETIC"] != nil, isAgy, "provider=\(pid ?? "nil")")

            XCTAssertEqual(env["CODEX_ACCESS_TOKEN"] != nil, isCodex, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["DEEPSEEK_API_KEY"] != nil, isDeepSeek, "provider=\(pid ?? "nil")")

            XCTAssertNil(env["GOOGLE_API_KEY"], "GOOGLE_API_KEY must never pass to \(pid ?? "nil")")
            XCTAssertEqual(env["GOOGLE_CLOUD_PROJECT"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertEqual(env["GOOGLE_CLOUD_PROJECT_ID"] != nil, isGemini, "provider=\(pid ?? "nil")")
            XCTAssertNil(env["GOOGLE_APPLICATION_CREDENTIALS"])
            XCTAssertNil(env["GOOGLE_CREDENTIALS"])
            XCTAssertNil(env["CLOUDSDK_AUTH_ACCESS_TOKEN"])

            // Runtime essentials and unrelated non-credential vars survive
            XCTAssertEqual(env["HOME"], "/tmp/synthetic-home")
            XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
            XCTAssertEqual(env["GOOGLE_NON_CREDENTIAL_SYNTHETIC"], "harmless-google-flag")
        }

        // Allowed own-provider overrides survive and override Keychain
        let geminiOverride = runner.buildEnvironment(
            baseEnvironment: ["HOME": "/tmp", "PATH": "/usr/bin"],
            for: ProviderCatalog.gemini,
            overrides: [
                "GEMINI_ACCESS_TOKEN": "ya29.candidate_override",
                "GEMINI_DISABLE_LOCAL_AUTH": "1",
                "GEMINI_API_KEY": "AIzaSyForbiddenEvenForGemini1234",
                "AGY_ACCESS_TOKEN": "ya29.forbidden_cross_provider",
            ]
        )
        XCTAssertEqual(geminiOverride["GEMINI_ACCESS_TOKEN"], "ya29.candidate_override")
        XCTAssertEqual(geminiOverride["GEMINI_DISABLE_LOCAL_AUTH"], "1")
        XCTAssertNil(geminiOverride["GEMINI_API_KEY"])
        XCTAssertNil(geminiOverride["AGY_ACCESS_TOKEN"])
    }

    func testAgyKeychainDiscoveryOutcomesExactTupleAndSecretFreeDiagnostics() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-kc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        // 1. Isolated HOME skips Keychain completely (zero queries)
        let isolatedKC = MockAgyKeychainReader(result: .payload(makeKeyringPayload()))
        let isolatedTransport = MockNativeHTTPTransport()
        let isolatedProbe = AgyNativeProbe(transport: isolatedTransport, keychain: isolatedKC)
        let isolatedReport = await isolatedProbe.run(environment: ["HOME": tempHome.path])
        XCTAssertTrue(isolatedKC.queries.isEmpty, "隔离 HOME 下绝不得查询真实钥匙串")
        XCTAssertTrue(isolatedTransport.calls.isEmpty)
        XCTAssertNil(isolatedReport.failure)
        XCTAssertTrue(isolatedReport.warnings.contains { $0.contains("隔离主目录环境") })
        XCTAssertFalse(isolatedReport.warnings.joined().contains(tempHome.path))

        // 2. Non-isolated HOME queries ONLY exact tuple (gemini, antigravity)
        let cases: [(AgyKeychainReadResult, String, String)] = [
            (.missing, "missing", "未检测到本机 AGY 登录态"),
            (.denied, "denied", "访问被拒绝或钥匙串已锁定"),
            (.timeout, "timeout", "钥匙串凭据超时"),
            (.nonzero, "nonzero", "钥匙串查询失败"),
            (.unreadable, "unreadable", "无法读取本机 AGY 钥匙串凭据"),
            (.payload("corrupt-" + fakeToken), "malformed", "钥匙串凭据格式异常"),
        ]
        for (kcResult, expectedOutcome, expectedPhrase) in cases {
            let kc = MockAgyKeychainReader(result: kcResult)
            let transport = MockNativeHTTPTransport()
            let probe = AgyNativeProbe(transport: transport, keychain: kc, realUserHomeOverride: tempHome)
            let discovery = probe.discoverOnly(environment: ["HOME": tempHome.path])
            XCTAssertEqual(discovery.outcome, expectedOutcome)
            XCTAssertEqual(kc.queries.count, 1)
            XCTAssertEqual(kc.queries[0].service, "gemini")
            XCTAssertEqual(kc.queries[0].account, "antigravity")

            let report = await probe.run(environment: ["HOME": tempHome.path])
            XCTAssertTrue(transport.calls.isEmpty)
            XCTAssertNil(report.failure)
            XCTAssertTrue(report.warnings.contains { $0.contains(expectedPhrase) }, "outcome=\(expectedOutcome) warnings=\(report.warnings)")
            let joined = report.warnings.joined(separator: " ")
            XCTAssertFalse(joined.contains("Gemini"))
            XCTAssertFalse(joined.lowercased().contains("agy login"))
            XCTAssertFalse(joined.contains("ya29."))
        }
    }

    func testAgyKeyringBase64LiveAggregationAndSourcePrecedence() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-live-\(UUID().uuidString)", isDirectory: true)
        let agyDir = tempHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: agyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let envToken = "ya29.precedenceEnvToken1234567890abcd"
        let customToken = "ya29.precedenceCustom1234567890abcdef"
        let defaultToken = "ya29.precedenceDefault1234567890abcde"
        let kcToken = "ya29.precedenceKeychain1234567890abcd"

        let customFile = tempHome.appendingPathComponent("custom_auth.json")
        try makeKeyringPayload(accessToken: customToken).write(to: customFile, atomically: true, encoding: .utf8)
        let defaultFile = agyDir.appendingPathComponent("auth.json")
        try makeKeyringPayload(accessToken: defaultToken).write(to: defaultFile, atomically: true, encoding: .utf8)

        let kc = MockAgyKeychainReader(result: .payload(makeKeyringPayload(accessToken: kcToken)))
        let probe = AgyNativeProbe(transport: MockNativeHTTPTransport(), keychain: kc, realUserHomeOverride: tempHome)

        XCTAssertEqual(probe.discoverOnly(environment: ["HOME": tempHome.path, "AGY_ACCESS_TOKEN": envToken, "AGY_AUTH_FILE": customFile.path]).selectedSource, "env")
        XCTAssertEqual(probe.discoverOnly(environment: ["HOME": tempHome.path, "AGY_AUTH_FILE": customFile.path]).selectedSource, "local_file")
        XCTAssertEqual(probe.discoverOnly(environment: ["HOME": tempHome.path]).selectedSource, "local_file")
        try FileManager.default.removeItem(at: defaultFile)
        XCTAssertEqual(probe.discoverOnly(environment: ["HOME": tempHome.path]).selectedSource, "keychain")

        // Live 200 conservative max aggregation from Keychain go-keyring-base64:
        let reset5hSummary = futureISO(4 * 3600)
        let reset5hGemini = futureISO(2 * 3600)
        let reset7d = futureISO(5 * 86_400)
        let transport = MockNativeHTTPTransport(responses: [
            jsonResponse([
                "cloudaicompanionProject": "proj-agy-123",
                "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
            ], url: AgyNativeProbe.loadCodeAssistURL),
            jsonResponse([
                "groups": [[
                    "buckets": [
                        ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": reset5hSummary],
                        ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.85, "resetTime": reset7d],
                    ],
                ]],
            ], url: AgyNativeProbe.retrieveQuotaSummaryURL),
            jsonResponse([
                "buckets": [
                    ["modelId": "gemini-2.5-pro", "remainingFraction": 0.41, "resetTime": reset5hGemini],
                    ["modelId": "gemini-2.5-flash", "remainingFraction": 0.90, "resetTime": reset5hSummary],
                ],
            ], url: AgyNativeProbe.retrieveQuotaURL),
        ])
        let liveProbe = AgyNativeProbe(transport: transport, keychain: kc, realUserHomeOverride: tempHome)
        let report = await liveProbe.run(environment: [
            "HOME": tempHome.path,
            "GOOGLE_CLOUD_PROJECT": "foreign-gcp-project-must-be-ignored",
            "GEMINI_API_KEY": "AIzaSyForeignGeminiApiKey12345678",
        ])
        XCTAssertNil(report.failure, report.failure ?? "")
        XCTAssertEqual(report.envelope?.account?.label, fakeEmail)
        XCTAssertEqual(report.envelope?.account?.plan, "Google AI Pro")
        XCTAssertEqual(report.envelope?.windows.count, 2)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "5h" })?.usedPercent, 59.0)
        XCTAssertEqual(report.envelope?.windows.first(where: { $0.id == "7d" })?.usedPercent, 15.0)
        XCTAssertEqual(transport.calls.count, 3)
        for req in transport.calls {
            XCTAssertEqual(req.headers["User-Agent"], "antigravity")
            XCTAssertEqual(req.headers["Authorization"], "Bearer \(kcToken)")
        }
        // Verify AGY ignored GOOGLE_CLOUD_PROJECT and used its own loadCodeAssist project
        let summaryBody = try JSONSerialization.jsonObject(with: XCTUnwrap(transport.calls[1].body)) as? [String: Any]
        XCTAssertEqual(summaryBody?["project"] as? String, "proj-agy-123")
    }

    func testAgy403PermissionDenialVs401AndBoundedOAuthRefresh() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-403-\(UUID().uuidString)", isDirectory: true)
        let agyDir = tempHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: agyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let authURL = agyDir.appendingPathComponent("auth.json")
        try makeKeyringPayload().write(to: authURL, atomically: true, encoding: .utf8)

        // 1. HTTP 403 does NOT claim expiration or missing AGY
        let transport403 = MockNativeHTTPTransport(responses: [
            jsonResponse(["error": "forbidden"], url: AgyNativeProbe.loadCodeAssistURL, status: 403),
        ])
        let probe403 = AgyNativeProbe(transport: transport403)
        let report403 = await probe403.run(environment: ["HOME": tempHome.path])
        XCTAssertNotNil(report403.failure)
        XCTAssertTrue(report403.failure?.contains("HTTP 403") ?? false)
        XCTAssertTrue(report403.failure?.contains("权限") ?? false)
        XCTAssertFalse(report403.failure?.contains("已过期") ?? true)
        XCTAssertFalse(report403.failure?.contains("未检测到本机 AGY 登录态") ?? true)
        XCTAssertFalse(report403.failure?.lowercased().contains("agy login") ?? true)
        XCTAssertFalse(report403.failure?.contains("Gemini") ?? true)

        // 2. Expired local auth without AGY client_id must NOT borrow GEMINI_OAUTH_CLIENT_ID
        try makeKeyringPayload(expiry: pastISO(300), clientID: nil).write(to: authURL, atomically: true, encoding: .utf8)
        let transportNoBorrow = MockNativeHTTPTransport()
        let probeNoBorrow = AgyNativeProbe(transport: transportNoBorrow)
        let reportNoBorrow = await probeNoBorrow.run(environment: [
            "HOME": tempHome.path,
            "GEMINI_OAUTH_CLIENT_ID": "gemini-client.apps.googleusercontent.com",
        ])
        XCTAssertTrue(transportNoBorrow.calls.isEmpty, "AGY 不得借用 GEMINI_OAUTH_CLIENT_ID")
        XCTAssertNotNil(reportNoBorrow.failure)

        // 3. Proactive in-memory refresh succeeds (zero disk writes) & rejected refresh stays bounded
        let expiredPayload = makeKeyringPayload(expiry: pastISO(300), clientID: fakeClientID)
        try expiredPayload.write(to: authURL, atomically: true, encoding: .utf8)
        let beforeBytes = try Data(contentsOf: authURL)

        let transportRefresh = MockNativeHTTPTransport(responses: [
            jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL),
            jsonResponse(["cloudaicompanionProject": "proj-1", "paidTier": ["name": "Pro"]], url: AgyNativeProbe.loadCodeAssistURL),
            jsonResponse(["groups": [["buckets": [
                ["window": "5h", "remainingFraction": 0.8, "resetTime": futureISO(3600)],
                ["window": "weekly", "remainingFraction": 0.9, "resetTime": futureISO(5 * 86_400)],
            ]]]], url: AgyNativeProbe.retrieveQuotaSummaryURL),
            jsonResponse(["buckets": []], url: AgyNativeProbe.retrieveQuotaURL),
        ])
        let probeRefresh = AgyNativeProbe(transport: transportRefresh)
        let refreshReport = await probeRefresh.run(environment: ["HOME": tempHome.path])
        XCTAssertNil(refreshReport.failure, refreshReport.failure ?? "")
        XCTAssertEqual(refreshReport.envelope?.windows.count, 2)
        XCTAssertEqual(try Data(contentsOf: authURL), beforeBytes, "刷新绝不可写盘")
        XCTAssertEqual(transportRefresh.calls[0].url, AgyNativeProbe.oauthTokenURL)
        XCTAssertEqual(transportRefresh.calls[1].headers["Authorization"], "Bearer \(fakeNewToken)")

        // Rejected refresh (HTTP 400)
        let transportReject = MockNativeHTTPTransport(responses: [
            jsonResponse(["error": "invalid_grant"], url: AgyNativeProbe.oauthTokenURL, status: 400),
        ])
        let rejectReport = await AgyNativeProbe(transport: transportReject).run(environment: ["HOME": tempHome.path])
        XCTAssertEqual(transportReject.calls.count, 1)
        XCTAssertTrue(rejectReport.failure?.contains("HTTP 400") ?? false)
        XCTAssertEqual(try Data(contentsOf: authURL), beforeBytes)
    }

    func testAgyTodayTokensAndFallbackWhenUnauthenticated() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-tokens-\(UUID().uuidString)", isDirectory: true)
        let logDir = tempHome.appendingPathComponent(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let transcript = """
        not json
        {"type":"USER_INPUT","created_at":"\(iso)","input_tokens":99999}
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":400,"output_tokens":150,"cache_read_tokens":250}
        """
        try transcript.write(to: logDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let probe = AgyNativeProbe(transport: MockNativeHTTPTransport())
        let report = await probe.run(environment: ["HOME": tempHome.path, "AGY_DISABLE_LOCAL_AUTH": "1"], now: now)
        XCTAssertNil(report.failure)
        XCTAssertTrue(report.envelope?.windows.isEmpty ?? false)
        XCTAssertEqual(report.envelope?.usage?.todayTokens, 800)
        XCTAssertEqual(report.envelope?.usage?.source, "local")
        XCTAssertTrue(report.warnings.contains { $0.contains("AGY_DISABLE_LOCAL_AUTH") })
    }

    func testAgyKeychainProactiveRefreshOnExpiryDateAndSupportedFieldsWritesBackPreservingUnknownFields() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-kc-wb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let reset5h = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let reset7d = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 86_400))

        func quotaSuccessResponses() -> [Result<NativeHTTPResponse, Error>] {
            [
                jsonResponse(["cloudaicompanionProject": "proj-wb-1", "paidTier": ["name": "Pro"]], url: AgyNativeProbe.loadCodeAssistURL),
                jsonResponse(["groups": [["buckets": [
                    ["window": "5h", "remainingFraction": 0.75, "resetTime": reset5h],
                    ["window": "weekly", "remainingFraction": 0.90, "resetTime": reset7d],
                ]]]], url: AgyNativeProbe.retrieveQuotaSummaryURL),
                jsonResponse(["buckets": []], url: AgyNativeProbe.retrieveQuotaURL),
            ]
        }

        // 1. Flat JSON + expiry_date (epoch ms) within proactive skew (now + 30s <= now + 60s):
        //    proactively refreshes via pinned oauth2.googleapis.com/token and writes back atomically preserving unknown fields.
        let nearExpiryMs = Int64((now.timeIntervalSince1970 + 30.0) * 1000.0)
        let flatInitialObj: [String: Any] = [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "token_type": "Bearer",
            "expiry_date": nearExpiryMs,
            "client_id": fakeClientID,
            "client_secret": "synthetic-client-secret-0001",
            "email": fakeEmail,
            "unknown_str": "keep-root-string",
            "unknown_num": 42,
            "unknown_bool": true,
            "unknown_array": ["a", "b"],
            "unknown_nested": ["k": "v"],
        ]
        let flatInitialRaw = String(decoding: try JSONSerialization.data(withJSONObject: flatInitialObj), as: UTF8.self)
        let flatStore = InMemoryAgyKeychainStore(initialPayload: flatInitialRaw)
        let flatTransport = MockNativeHTTPTransport(responses: [
            jsonResponse(["access_token": fakeNewToken, "expires_in": 3600, "token_type": "Bearer"], url: AgyNativeProbe.oauthTokenURL),
        ] + quotaSuccessResponses())

        let flatProbe = AgyNativeProbe(transport: flatTransport, keychain: flatStore, realUserHomeOverride: tempHome)
        let flatReport = await flatProbe.run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNil(flatReport.failure, flatReport.failure ?? "")
        XCTAssertEqual(flatReport.envelope?.windows.count, 2)
        XCTAssertEqual(flatStore.readQueries.count, 1)
        XCTAssertEqual(flatStore.writeCalls.count, 1)
        XCTAssertEqual(flatStore.writeCalls[0].service, "gemini")
        XCTAssertEqual(flatStore.writeCalls[0].account, "antigravity")
        XCTAssertEqual(flatTransport.calls[0].url, AgyNativeProbe.oauthTokenURL)
        XCTAssertEqual(flatTransport.calls[0].expectedHost, AgyNativeProbe.oauthTokenHost)
        XCTAssertEqual(flatTransport.calls[1].headers["Authorization"], "Bearer \(fakeNewToken)")

        let persistedFlatRaw = try XCTUnwrap(flatStore.currentPayload)
        XCTAssertFalse(persistedFlatRaw.hasPrefix(AgyNativeProbe.goKeyringBase64Prefix), "原始裸 JSON 应保持裸 JSON 格式")
        let persistedFlat = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(persistedFlatRaw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(persistedFlat["access_token"] as? String, fakeNewToken)
        XCTAssertEqual(persistedFlat["refresh_token"] as? String, fakeRefresh, "响应未轮换 refresh_token 时必须保留原值")
        XCTAssertEqual(persistedFlat["client_id"] as? String, fakeClientID)
        XCTAssertEqual(persistedFlat["client_secret"] as? String, "synthetic-client-secret-0001")
        XCTAssertEqual(persistedFlat["unknown_str"] as? String, "keep-root-string")
        XCTAssertEqual(persistedFlat["unknown_num"] as? Int, 42)
        XCTAssertEqual(persistedFlat["unknown_bool"] as? Bool, true)
        XCTAssertEqual(persistedFlat["unknown_array"] as? [String], ["a", "b"])
        XCTAssertEqual((persistedFlat["unknown_nested"] as? [String: String])?["k"], "v")
        let expectedNewMs = Int64((now.timeIntervalSince1970 + 3600.0) * 1000.0)
        XCTAssertEqual((persistedFlat["expiry_date"] as? NSNumber)?.int64Value, expectedNewMs)

        // 后续立即再次查询：应直接读取写回后的新令牌，不再触发 OAuth 刷新也不再写回钥匙串
        let followUpTransport = MockNativeHTTPTransport(responses: quotaSuccessResponses())
        let followUpProbe = AgyNativeProbe(transport: followUpTransport, keychain: flatStore, realUserHomeOverride: tempHome)
        let followUpReport = await followUpProbe.run(environment: ["HOME": tempHome.path], now: now.addingTimeInterval(10))
        XCTAssertNil(followUpReport.failure, followUpReport.failure ?? "")
        XCTAssertEqual(flatStore.writeCalls.count, 1, "未临期时绝不应重复写回钥匙串")
        XCTAssertEqual(followUpTransport.calls.count, 3)
        XCTAssertEqual(followUpTransport.calls[0].url, AgyNativeProbe.loadCodeAssistURL)
        XCTAssertEqual(followUpTransport.calls[0].headers["Authorization"], "Bearer \(fakeNewToken)")

        // 2. AGY 1.5.13 go-keyring-base64: 嵌套 token 结构（含 Go RFC3339Nano 9 位小数秒 + 轮换 refresh_token + 未知字段）
        let rotatedRefresh = "1//0eSyntheticRotatedRefreshToken9999999999"
        let nestedInitialObj: [String: Any] = [
            "auth_method": "oauth",
            "id_token_email": fakeEmail,
            "writer_id": "agy-1.5.13-writer",
            "custom_root_meta": ["keep": true, "ver": 3],
            "token": [
                "access_token": fakeToken,
                "token_type": "Bearer",
                "refresh_token": fakeRefresh,
                "expiry": "2025-01-01T00:00:00.123456789Z",
                "expires_in": 3599,
                "custom_token_meta": "keep-token-field",
            ],
        ]
        let nestedRawData = try JSONSerialization.data(withJSONObject: nestedInitialObj)
        let nestedPayload = AgyNativeProbe.goKeyringBase64Prefix + nestedRawData.base64EncodedString()
        let nestedStore = InMemoryAgyKeychainStore(initialPayload: nestedPayload)
        let nestedTransport = MockNativeHTTPTransport(responses: [
            jsonResponse([
                "access_token": fakeNewToken,
                "refresh_token": rotatedRefresh,
                "expires_in": 3599,
                "token_type": "Bearer",
            ], url: AgyNativeProbe.oauthTokenURL),
        ] + quotaSuccessResponses())
        let nestedProbe = AgyNativeProbe(transport: nestedTransport, keychain: nestedStore, realUserHomeOverride: tempHome)
        let nestedReport = await nestedProbe.run(
            environment: [
                "HOME": tempHome.path,
                "AGY_OAUTH_CLIENT_ID": fakeClientID,
            ],
            now: now
        )
        XCTAssertNil(nestedReport.failure, nestedReport.failure ?? "")
        XCTAssertEqual(nestedStore.writeCalls.count, 1)
        let persistedNestedRaw = try XCTUnwrap(nestedStore.currentPayload)
        XCTAssertTrue(persistedNestedRaw.hasPrefix(AgyNativeProbe.goKeyringBase64Prefix), "必须保留 go-keyring-base64: 封装前缀")
        let decodedNestedData = try XCTUnwrap(
            Data(base64Encoded: String(persistedNestedRaw.dropFirst(AgyNativeProbe.goKeyringBase64Prefix.count)))
        )
        let persistedNested = try XCTUnwrap(try JSONSerialization.jsonObject(with: decodedNestedData) as? [String: Any])
        XCTAssertEqual(persistedNested["auth_method"] as? String, "oauth")
        XCTAssertEqual(persistedNested["id_token_email"] as? String, fakeEmail)
        XCTAssertEqual(persistedNested["writer_id"] as? String, "agy-1.5.13-writer")
        XCTAssertNil(persistedNested["client_id"], "环境变量注入的 client_id 不应凭空写入钥匙串载荷")
        let persistedRootMeta = try XCTUnwrap(persistedNested["custom_root_meta"] as? [String: Any])
        XCTAssertEqual(persistedRootMeta["keep"] as? Bool, true)
        XCTAssertEqual(persistedRootMeta["ver"] as? Int, 3)

        let persistedToken = try XCTUnwrap(persistedNested["token"] as? [String: Any])
        XCTAssertEqual(persistedToken["access_token"] as? String, fakeNewToken)
        XCTAssertEqual(persistedToken["refresh_token"] as? String, rotatedRefresh)
        XCTAssertEqual(persistedToken["expires_in"] as? Int, 3599)
        XCTAssertEqual(persistedToken["custom_token_meta"] as? String, "keep-token-field")
        let newExpiryStr = try XCTUnwrap(persistedToken["expiry"] as? String)
        let parsedNewExpiry = try XCTUnwrap(ProbeDate.parse(newExpiryStr))
        XCTAssertEqual(parsedNewExpiry.timeIntervalSince1970, now.timeIntervalSince1970 + 3599, accuracy: 1.0)

        // 3. 字符串化的毫秒 expiry_date 必须在 skew 内触发刷新并保留字符串毫秒格式；超出 skew (+61s) 则不刷新不写回
        let stringMsNear = String(Int64((now.timeIntervalSince1970 + 20.0) * 1000.0))
        let stringMsObj: [String: Any] = [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "expiry_date": stringMsNear,
            "client_id": fakeClientID,
        ]
        let stringMsRaw = String(decoding: try JSONSerialization.data(withJSONObject: stringMsObj), as: UTF8.self)
        let stringMsStore = InMemoryAgyKeychainStore(initialPayload: stringMsRaw)
        let stringMsTransport = MockNativeHTTPTransport(responses: [
            jsonResponse(["access_token": fakeNewToken, "expires_in": 1800], url: AgyNativeProbe.oauthTokenURL),
        ] + quotaSuccessResponses())
        let stringMsReport = await AgyNativeProbe(
            transport: stringMsTransport,
            keychain: stringMsStore,
            realUserHomeOverride: tempHome
        ).run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNil(stringMsReport.failure, stringMsReport.failure ?? "")
        XCTAssertEqual(stringMsStore.writeCalls.count, 1)
        let persistedStringMs = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(stringMsStore.currentPayload).utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            persistedStringMs["expiry_date"] as? String,
            String(Int64((now.timeIntervalSince1970 + 1800.0) * 1000.0))
        )

        // 超出提前刷新窗口（now + 61s > now + 60s）不得主动刷新也不得写回钥匙串
        let outsideSkewObj: [String: Any] = [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "expiry_date": Int64((now.timeIntervalSince1970 + 61.0) * 1000.0),
            "client_id": fakeClientID,
        ]
        let outsideStore = InMemoryAgyKeychainStore(
            initialPayload: String(decoding: try JSONSerialization.data(withJSONObject: outsideSkewObj), as: UTF8.self)
        )
        let outsideTransport = MockNativeHTTPTransport(responses: quotaSuccessResponses())
        let outsideReport = await AgyNativeProbe(
            transport: outsideTransport,
            keychain: outsideStore,
            realUserHomeOverride: tempHome
        ).run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNil(outsideReport.failure, outsideReport.failure ?? "")
        XCTAssertTrue(outsideStore.writeCalls.isEmpty)
        XCTAssertEqual(outsideTransport.calls.count, 3)
        XCTAssertEqual(outsideTransport.calls[0].headers["Authorization"], "Bearer \(fakeToken)")
    }

    func testAgyKeychainReactive401RefreshWritesBackAndNeverWritesAuthFiles() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-401-wb-\(UUID().uuidString)", isDirectory: true)
        let agyDir = tempHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: agyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let reset5h = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let reset7d = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 86_400))

        // 1. Keychain 凭据未到 expiry_date 但服务端返回 401 -> 被动刷新一次并写回钥匙串
        let validFutureMs = Int64((now.timeIntervalSince1970 + 3600.0) * 1000.0)
        let kcObj: [String: Any] = [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "expires_at": validFutureMs,
            "client_id": fakeClientID,
            "keep_extra": "reactive-401-marker",
        ]
        let kcStore = InMemoryAgyKeychainStore(
            initialPayload: String(decoding: try JSONSerialization.data(withJSONObject: kcObj), as: UTF8.self)
        )
        let kcTransport = MockNativeHTTPTransport(responses: [
            jsonResponse(["error": "unauthorized"], url: AgyNativeProbe.loadCodeAssistURL, status: 401),
            jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL),
            jsonResponse(["cloudaicompanionProject": "proj-401", "paidTier": ["name": "Pro"]], url: AgyNativeProbe.loadCodeAssistURL),
            jsonResponse(["groups": [["buckets": [
                ["window": "5h", "remainingFraction": 0.5, "resetTime": reset5h],
                ["window": "weekly", "remainingFraction": 0.8, "resetTime": reset7d],
            ]]]], url: AgyNativeProbe.retrieveQuotaSummaryURL),
            jsonResponse(["buckets": []], url: AgyNativeProbe.retrieveQuotaURL),
        ])
        let kcReport = await AgyNativeProbe(
            transport: kcTransport,
            keychain: kcStore,
            realUserHomeOverride: tempHome
        ).run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNil(kcReport.failure, kcReport.failure ?? "")
        XCTAssertEqual(kcReport.envelope?.windows.count, 2)
        XCTAssertEqual(kcStore.writeCalls.count, 1)
        XCTAssertEqual(kcStore.writeCalls[0].service, "gemini")
        XCTAssertEqual(kcStore.writeCalls[0].account, "antigravity")
        let updatedKC = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(kcStore.currentPayload).utf8)) as? [String: Any]
        )
        XCTAssertEqual(updatedKC["access_token"] as? String, fakeNewToken)
        XCTAssertEqual(updatedKC["keep_extra"] as? String, "reactive-401-marker")

        // 2. auth.json 本地凭据过期刷新：绝不可写回 auth.json，也绝不可写入钥匙串
        let authURL = agyDir.appendingPathComponent("auth.json")
        let expiredFileObj: [String: Any] = [
            "access_token": fakeToken,
            "refresh_token": fakeRefresh,
            "expiry_date": Int64((now.timeIntervalSince1970 - 120.0) * 1000.0),
            "client_id": fakeClientID,
        ]
        let beforeFileData = try JSONSerialization.data(withJSONObject: expiredFileObj)
        try beforeFileData.write(to: authURL)

        let untouchedStore = InMemoryAgyKeychainStore(initialPayload: makeKeyringPayload())
        let fileTransport = MockNativeHTTPTransport(responses: [
            jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL),
            jsonResponse(["cloudaicompanionProject": "proj-file", "paidTier": ["name": "Pro"]], url: AgyNativeProbe.loadCodeAssistURL),
            jsonResponse(["groups": [["buckets": [
                ["window": "5h", "remainingFraction": 0.6, "resetTime": reset5h],
                ["window": "weekly", "remainingFraction": 0.7, "resetTime": reset7d],
            ]]]], url: AgyNativeProbe.retrieveQuotaSummaryURL),
            jsonResponse(["buckets": []], url: AgyNativeProbe.retrieveQuotaURL),
        ])
        let fileReport = await AgyNativeProbe(
            transport: fileTransport,
            keychain: untouchedStore,
            realUserHomeOverride: tempHome
        ).run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNil(fileReport.failure, fileReport.failure ?? "")
        XCTAssertEqual(try Data(contentsOf: authURL), beforeFileData, "刷新绝不可改写本地 auth.json")
        XCTAssertTrue(untouchedStore.readQueries.isEmpty)
        XCTAssertTrue(untouchedStore.writeCalls.isEmpty, "来自本地文件的凭据刷新绝不可写回钥匙串")
    }

    func testAgyRefreshRejectsInvalidExpiryMetadataAndFailsClosedWithoutWritingKeychain() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-bad-exp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let expiredKC = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "access_token": fakeToken,
                "refresh_token": fakeRefresh,
                "expiry_date": 0,
                "client_id": fakeClientID,
            ]),
            as: UTF8.self
        )

        let malformedRefreshBodies: [(label: String, body: [String: Any])] = [
            ("missing_expiry_metadata", ["access_token": fakeNewToken]),
            ("zero_expires_in", ["access_token": fakeNewToken, "expires_in": 0]),
            ("negative_expires_in", ["access_token": fakeNewToken, "expires_in": -60]),
            ("boolean_expires_in", ["access_token": fakeNewToken, "expires_in": true]),
            ("non_numeric_expires_in", ["access_token": fakeNewToken, "expires_in": "soon"]),
            ("overflow_expires_in", ["access_token": fakeNewToken, "expires_in": 1e100]),
            ("excessive_expires_in", ["access_token": fakeNewToken, "expires_in": AgyNativeProbe.maxRefreshExpiresInSeconds + 1]),
            ("past_explicit_expiry_date", ["access_token": fakeNewToken, "expiry_date": Int64((now.timeIntervalSince1970 - 10) * 1000)]),
            ("unparseable_explicit_expiry", ["access_token": fakeNewToken, "expiry": "not-a-timestamp"]),
            ("control_char_access_token", ["access_token": "ya29.bad\r\nX-Inject: 1", "expires_in": 3600]),
            ("empty_rotated_refresh_token", ["access_token": fakeNewToken, "expires_in": 3600, "refresh_token": "   "]),
        ]

        for testCase in malformedRefreshBodies {
            let store = InMemoryAgyKeychainStore(initialPayload: expiredKC)
            let transport = MockNativeHTTPTransport(responses: [
                jsonResponse(testCase.body, url: AgyNativeProbe.oauthTokenURL),
            ])
            let probe = AgyNativeProbe(transport: transport, keychain: store, realUserHomeOverride: tempHome)
            let report = await probe.run(environment: ["HOME": tempHome.path], now: now)

            XCTAssertNotNil(report.failure, "case=\(testCase.label) 必须 fail-closed 拒绝非法刷新响应")
            XCTAssertTrue(store.writeCalls.isEmpty, "case=\(testCase.label) 非法刷新响应绝不可写回钥匙串")
            XCTAssertEqual(store.currentPayload, expiredKC, "case=\(testCase.label) 原钥匙串条目必须完好未改")
            XCTAssertEqual(transport.calls.count, 1, "case=\(testCase.label) 失败后不得继续请求配额接口")

            let combined = [report.failure ?? "", report.warnings.joined(separator: " ")].joined(separator: " ")
            XCTAssertFalse(combined.contains(fakeToken), "case=\(testCase.label) 绝不可泄露旧令牌")
            XCTAssertFalse(combined.contains(fakeNewToken), "case=\(testCase.label) 绝不可泄露新令牌")
            XCTAssertFalse(combined.contains(fakeRefresh), "case=\(testCase.label) 绝不可泄露刷新令牌")
            XCTAssertFalse(combined.contains("ya29."), "case=\(testCase.label) 绝不可泄露原始 token 前缀")
        }
    }

    func testAgyKeychainWriteBackFailureModesFailClosedAndRedactSecrets() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-wb-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_763_800_000)
        let expiredKC = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "access_token": fakeToken,
                "refresh_token": fakeRefresh,
                "expiry_date": Int64((now.timeIntervalSince1970 - 30) * 1000),
                "client_id": fakeClientID,
            ]),
            as: UTF8.self
        )

        let writeFailureCases: [(AgyKeychainWriteResult, String)] = [
            (.missing, "未找到对应钥匙串条目"),
            (.denied, "写回钥匙串被拒绝"),
            (.timeout, "写回钥匙串超时"),
            (.nonzero, "写回钥匙串失败"),
            (.rejected, "写回钥匙串校验未通过"),
        ]

        for (forcedResult, expectedPhrase) in writeFailureCases {
            let store = InMemoryAgyKeychainStore(initialPayload: expiredKC, forcedWriteResult: forcedResult)
            let transport = MockNativeHTTPTransport(responses: [
                jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL),
            ])
            let probe = AgyNativeProbe(transport: transport, keychain: store, realUserHomeOverride: tempHome)
            let report = await probe.run(environment: ["HOME": tempHome.path], now: now)

            XCTAssertEqual(store.writeCalls.count, 1)
            XCTAssertEqual(store.writeCalls[0].service, "gemini")
            XCTAssertEqual(store.writeCalls[0].account, "antigravity")
            XCTAssertEqual(transport.calls.count, 1, "钥匙串写回失败后必须 fail-closed，不得静默继续")
            XCTAssertNotNil(report.failure)
            XCTAssertTrue(report.failure?.contains(expectedPhrase) ?? false, "result=\(forcedResult) failure=\(report.failure ?? "nil")")

            let combined = [report.failure ?? "", report.warnings.joined(separator: " ")].joined(separator: " ")
            XCTAssertFalse(combined.contains("Gemini"))
            XCTAssertFalse(combined.lowercased().contains("agy login"))
            XCTAssertFalse(combined.contains(fakeToken))
            XCTAssertFalse(combined.contains(fakeNewToken))
            XCTAssertFalse(combined.contains(fakeRefresh))
            XCTAssertFalse(combined.contains("ya29."))
        }

        // 只读 Mock（未实现 AgyKeychainWriting）对 Keychain 凭据触发刷新时也必须 fail-closed
        let readOnlyKC = MockAgyKeychainReader(result: .payload(expiredKC))
        let roTransport = MockNativeHTTPTransport(responses: [
            jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL),
        ])
        let roProbe = AgyNativeProbe(transport: roTransport, keychain: readOnlyKC, realUserHomeOverride: tempHome)
        let roReport = await roProbe.run(environment: ["HOME": tempHome.path], now: now)
        XCTAssertNotNil(roReport.failure)
        XCTAssertTrue(roReport.failure?.contains("写回钥匙串校验未通过") ?? false)
        XCTAssertEqual(roTransport.calls.count, 1)
    }

    func testAgyKeychainCredentialsCachedAcrossAutoRefreshesAndEvictedOnAuthFailure() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-cache-\(UUID().uuidString)", isDirectory: true)
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-lens-agy-isolated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempHome)
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let baseNow = Date(timeIntervalSince1970: 1_763_800_000)
        let expiryISO = ISO8601DateFormatter().string(from: baseNow.addingTimeInterval(3600))
        let reset5h = ISO8601DateFormatter().string(from: baseNow.addingTimeInterval(7200))
        let reset7d = ISO8601DateFormatter().string(from: baseNow.addingTimeInterval(5 * 86_400))

        func quotaSuccessResponses() -> [Result<NativeHTTPResponse, Error>] {
            [
                jsonResponse(["cloudaicompanionProject": "proj-cache-1", "paidTier": ["name": "Pro"]], url: AgyNativeProbe.loadCodeAssistURL),
                jsonResponse(["groups": [["buckets": [
                    ["window": "5h", "remainingFraction": 0.75, "resetTime": reset5h],
                    ["window": "weekly", "remainingFraction": 0.90, "resetTime": reset7d],
                ]]]], url: AgyNativeProbe.retrieveQuotaSummaryURL),
                jsonResponse(["buckets": []], url: AgyNativeProbe.retrieveQuotaURL),
            ]
        }

        let initialPayload = makeKeyringPayload(
            accessToken: fakeToken,
            refreshToken: fakeRefresh,
            expiry: expiryISO,
            email: fakeEmail,
            clientID: fakeClientID
        )
        let store = InMemoryAgyKeychainStore(initialPayload: initialPayload)
        let transport = MockNativeHTTPTransport(
            responses:
                // 1. First probe (reads Keychain)
                quotaSuccessResponses()
                // 2. Second probe 60s later (hits cache)
                + quotaSuccessResponses()
                // 3. Third probe past expiry (proactive refresh + write-back + cache update)
                + [jsonResponse(["access_token": fakeNewToken, "expires_in": 3600], url: AgyNativeProbe.oauthTokenURL)]
                + quotaSuccessResponses()
                // 4. Fourth probe 60s later (uses updated cached token, zero Keychain reads/writes)
                + quotaSuccessResponses()
                // 5. Fifth probe gets HTTP 403 -> evicts cache
                + [jsonResponse(["error": "forbidden"], url: AgyNativeProbe.loadCodeAssistURL, status: 403)]
                // 6. Sixth probe re-reads Keychain after eviction
                + quotaSuccessResponses()
        )

        let probe = AgyNativeProbe(transport: transport, keychain: store, realUserHomeOverride: tempHome)
        let env = ["HOME": tempHome.path]

        // 1. First run reads Keychain once and returns 2 windows
        let r1 = await probe.run(environment: env, now: baseNow)
        XCTAssertNil(r1.failure, r1.failure ?? "")
        XCTAssertEqual(r1.envelope?.windows.count, 2)
        XCTAssertEqual(store.readQueries.count, 1)
        XCTAssertEqual(store.writeCalls.count, 0)
        XCTAssertEqual(transport.calls[0].headers["Authorization"], "Bearer \(fakeToken)")

        // 2. Second run (60s auto-refresh) reuses in-memory cache without touching Keychain
        let r2 = await probe.run(environment: env, now: baseNow.addingTimeInterval(60))
        XCTAssertNil(r2.failure, r2.failure ?? "")
        XCTAssertEqual(r2.envelope?.windows.count, 2)
        XCTAssertEqual(store.readQueries.count, 1)
        XCTAssertEqual(store.writeCalls.count, 0)
        XCTAssertEqual(transport.calls[3].headers["Authorization"], "Bearer \(fakeToken)")

        // 3. Advancing past expiry refreshes OAuth once, writes back, and updates cache
        let expiredNow = baseNow.addingTimeInterval(3700)
        let r3 = await probe.run(environment: env, now: expiredNow)
        XCTAssertNil(r3.failure, r3.failure ?? "")
        XCTAssertEqual(r3.envelope?.windows.count, 2)
        XCTAssertEqual(store.readQueries.count, 1)
        XCTAssertEqual(store.writeCalls.count, 1)
        XCTAssertEqual(transport.calls[6].url, AgyNativeProbe.oauthTokenURL)
        XCTAssertEqual(transport.calls[7].headers["Authorization"], "Bearer \(fakeNewToken)")

        // 4. Following run uses updated cached token with no Keychain read or write
        let r4 = await probe.run(environment: env, now: expiredNow.addingTimeInterval(60))
        XCTAssertNil(r4.failure, r4.failure ?? "")
        XCTAssertEqual(r4.envelope?.windows.count, 2)
        XCTAssertEqual(store.readQueries.count, 1)
        XCTAssertEqual(store.writeCalls.count, 1)
        XCTAssertEqual(transport.calls[10].headers["Authorization"], "Bearer \(fakeNewToken)")

        // 5. Auth error (HTTP 403) evicts cache; subsequent run re-reads Keychain
        let r5 = await probe.run(environment: env, now: expiredNow.addingTimeInterval(120))
        XCTAssertNotNil(r5.failure)
        XCTAssertTrue(r5.failure?.contains("HTTP 403") ?? false)
        XCTAssertEqual(store.readQueries.count, 1)

        let r6 = await probe.run(environment: env, now: expiredNow.addingTimeInterval(180))
        XCTAssertNil(r6.failure, r6.failure ?? "")
        XCTAssertEqual(r6.envelope?.windows.count, 2)
        XCTAssertEqual(store.readQueries.count, 2)
        XCTAssertEqual(transport.calls[14].headers["Authorization"], "Bearer \(fakeNewToken)")

        // 6. Isolated HOME never reads cached credentials from realUserHomeOverride
        let callsBeforeIsolated = transport.calls.count
        let isolatedReport = await probe.run(environment: ["HOME": isolatedHome.path], now: expiredNow.addingTimeInterval(240))
        XCTAssertNil(isolatedReport.failure)
        XCTAssertTrue(isolatedReport.warnings.contains { $0.contains("隔离主目录环境") })
        XCTAssertEqual(store.readQueries.count, 2)
        XCTAssertEqual(transport.calls.count, callsBeforeIsolated)
    }
}
