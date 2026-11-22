import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import UsageLensKit

// MARK: - 真实 URLSession 流式测试用 URLProtocol

private final class StreamingURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    var requestsStarted = 0
    var requestedURLs: [URL] = []
    var bodyChunksSent = 0
    var totalBytesSent = 0
    var didStopLoading = false

    func reset() {
        lock.withLock {
            requestsStarted = 0
            requestedURLs = []
            bodyChunksSent = 0
            totalBytesSent = 0
            didStopLoading = false
        }
    }

    func recordStart(url: URL?) {
        lock.withLock {
            requestsStarted += 1
            if let url { requestedURLs.append(url) }
        }
    }

    func recordChunk(bytes: Int) {
        lock.withLock {
            bodyChunksSent += 1
            totalBytesSent += bytes
        }
    }

    func markStopped() {
        lock.withLock { didStopLoading = true }
    }

    func snapshot() -> (requestsStarted: Int, urls: [URL], chunks: Int, bytes: Int, stopped: Bool) {
        lock.withLock { (requestsStarted, requestedURLs, bodyChunksSent, totalBytesSent, didStopLoading) }
    }
}

private enum StreamingMockScenario: Sendable {
    case declaredOversized(contentLength: String, totalChunks: Int, chunkSize: Int)
    case chunkedStream(totalChunks: Int, chunkSize: Int, chunkDelayMs: UInt32)
    case redirectWithLocation(statusCode: Int, target: URL)
    case redirectDirect(statusCode: Int)
    case infiniteSlowStream
}

private final class StreamingMockRegistry: @unchecked Sendable {
    static let shared = StreamingMockRegistry()
    private let lock = NSLock()
    var scenario: StreamingMockScenario = .chunkedStream(totalChunks: 1, chunkSize: 16, chunkDelayMs: 0)
    let state = StreamingURLProtocolState()

    func configure(_ scenario: StreamingMockScenario) {
        lock.withLock {
            self.scenario = scenario
        }
        state.reset()
    }

    func currentScenario() -> StreamingMockScenario {
        lock.withLock { scenario }
    }
}

private final class StreamingMockURLProtocol: URLProtocol {
    private let stopLock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        stopLock.withLock { stopped }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = StreamingMockRegistry.shared.state
        state.recordStart(url: request.url)
        let scenario = StreamingMockRegistry.shared.currentScenario()
        let url = request.url ?? URL(string: "https://daily-cloudcode-pa.googleapis.com/")!

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch scenario {
            case .declaredOversized(let contentLength, let totalChunks, let chunkSize):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Content-Length": contentLength,
                    ]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                // 等待 URLSessionDataDelegate 在响应头阶段返回 .cancel -> stopLoading()
                for _ in 0..<40 {
                    if self.isStopped { return }
                    usleep(5_000)
                }
                let chunk = Data(repeating: 0x41, count: chunkSize)
                for _ in 0..<totalChunks {
                    if self.isStopped { return }
                    state.recordChunk(bytes: chunk.count)
                    self.client?.urlProtocol(self, didLoad: chunk)
                    usleep(2_000)
                }
                if !self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }

            case .chunkedStream(let totalChunks, let chunkSize, let chunkDelayMs):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Transfer-Encoding": "chunked",
                    ]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let chunk = Data(repeating: 0x42, count: chunkSize)
                for _ in 0..<totalChunks {
                    if self.isStopped { return }
                    state.recordChunk(bytes: chunk.count)
                    self.client?.urlProtocol(self, didLoad: chunk)
                    if chunkDelayMs > 0 {
                        usleep(chunkDelayMs * 1_000)
                    }
                }
                if !self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }

            case .redirectWithLocation(let statusCode, let target):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString]
                )!
                var redirected = URLRequest(url: target)
                redirected.httpMethod = self.request.httpMethod
                self.client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)

            case .redirectDirect(let statusCode):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }

            case .infiniteSlowStream:
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Transfer-Encoding": "chunked"]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                while !self.isStopped {
                    usleep(10_000)
                }
            }
        }
    }

    override func stopLoading() {
        stopLock.withLock { stopped = true }
        StreamingMockRegistry.shared.state.markStopped()
    }
}

// MARK: - 不可中断阻塞型 Keychain Mock

private final class SlowBlockingAgyKeychainReader: AgyKeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let blockSeconds: TimeInterval
    private var _callCount = 0

    init(blockSeconds: TimeInterval = 3.0) {
        self.blockSeconds = blockSeconds
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func unblock() {
        releaseSemaphore.signal()
    }

    func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult {
        lock.withLock { _callCount += 1 }
        _ = releaseSemaphore.wait(timeout: .now() + blockSeconds)
        return .missing
    }
}

private final class ImmediateAgyKeychainReader: AgyKeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: AgyKeychainReadResult
    private var _callCount = 0

    init(result: AgyKeychainReadResult = .payload("{\"access_token\":\"synthetic\"}")) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func readGenericPassword(service: String, account: String) -> AgyKeychainReadResult {
        lock.withLock { _callCount += 1 }
        return result
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.withLock { _value }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }
}

// MARK: - 四项阻断缺陷回归测试套件

final class NativeSafetyAndLifecycleTests: XCTestCase {

    // MARK: - 缺陷 1：DeepSeek zstd 子进程实际环境边界（仅允许最小化白名单，严禁继承父环境与凭据）

    func testDeepSeekZstdChildReceivesStrictMinimalEnvironmentOnly() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("usage-lens-zstd-env-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = tempDir.appendingPathComponent(".dsh/sessions/s1", isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let sessionFile = sessionDir.appendingPathComponent("session.v4.jsonl.zstd")
        try Data("synthetic-zstd-placeholder".utf8).write(to: sessionFile)

        let reportFile = tempDir.appendingPathComponent("child-env-booleans.json")
        let fakeZstd = tempDir.appendingPathComponent("fake-zstd.sh")

        // 注入合成标记到真实父进程环境（测完立即恢复原值，绝不打印任何真实值）
        let syntheticParentInjections: [String: String] = [
            "GEMINI_ACCESS_TOKEN": "ya29.parent_zstd_leak_marker",
            "GEMINI_API_KEY": "AIzaSyParentZstdLeakMarker1234",
            "GEMINI_OAUTH_CLIENT_SECRET": "parent-gemini-secret-marker",
            "GEMINI_FUTURE_SYNTHETIC": "parent-gemini-future-marker",
            "AGY_ACCESS_TOKEN": "ya29.parent_agy_zstd_leak_marker",
            "AGY_OAUTH_CLIENT_SECRET": "parent-agy-secret-marker",
            "AGY_FUTURE_SYNTHETIC": "parent-agy-future-marker",
            "CODEX_ACCESS_TOKEN": "sk-parent-codex-zstd-leak-marker",
            "DEEPSEEK_API_KEY": "sk-parent-deepseek-zstd-leak-marker",
            "GOOGLE_API_KEY": "AIzaSyParentGoogleZstdLeakMarker",
            "GOOGLE_CLOUD_PROJECT": "parent-gcp-project-marker",
            "GOOGLE_CLOUD_PROJECT_ID": "parent-gcp-project-id-marker",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/synthetic-parent-adc.json",
            "GOOGLE_CREDENTIALS": "synthetic-parent-google-creds",
            "CLOUDSDK_AUTH_ACCESS_TOKEN": "ya29.parent_cloudsdk_leak_marker",
            "USAGE_LENS_SYNTHETIC_PARENT_SECRET": "unrelated-parent-secret-marker",
        ]

        var savedOriginals: [String: String?] = [:]
        for (key, value) in syntheticParentInjections {
            if let existing = getenv(key) {
                savedOriginals[key] = String(cString: existing)
            } else {
                savedOriginals[key] = nil
            }
            setenv(key, value, 1)
        }
        defer {
            for (key, original) in savedOriginals {
                if let original {
                    setenv(key, original, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        // 子进程脚本仅输出各变量存在性布尔值（绝不回显变量值），同时输出合法 DeepSeek event JSONL。
        let nowEpoch = Int(Date().timeIntervalSince1970)
        let script = """
        #!/bin/sh
        has_var() {
          eval "val=\\${$1+set}"
          if [ "$val" = "set" ]; then echo true; else echo false; fi
        }
        cat <<EOF > "\(reportFile.path)"
        {
          "PATH": $(has_var PATH),
          "GEMINI_ACCESS_TOKEN": $(has_var GEMINI_ACCESS_TOKEN),
          "GEMINI_API_KEY": $(has_var GEMINI_API_KEY),
          "GEMINI_OAUTH_CLIENT_SECRET": $(has_var GEMINI_OAUTH_CLIENT_SECRET),
          "GEMINI_FUTURE_SYNTHETIC": $(has_var GEMINI_FUTURE_SYNTHETIC),
          "AGY_ACCESS_TOKEN": $(has_var AGY_ACCESS_TOKEN),
          "AGY_OAUTH_CLIENT_SECRET": $(has_var AGY_OAUTH_CLIENT_SECRET),
          "AGY_FUTURE_SYNTHETIC": $(has_var AGY_FUTURE_SYNTHETIC),
          "CODEX_ACCESS_TOKEN": $(has_var CODEX_ACCESS_TOKEN),
          "DEEPSEEK_API_KEY": $(has_var DEEPSEEK_API_KEY),
          "GOOGLE_API_KEY": $(has_var GOOGLE_API_KEY),
          "GOOGLE_CLOUD_PROJECT": $(has_var GOOGLE_CLOUD_PROJECT),
          "GOOGLE_CLOUD_PROJECT_ID": $(has_var GOOGLE_CLOUD_PROJECT_ID),
          "GOOGLE_APPLICATION_CREDENTIALS": $(has_var GOOGLE_APPLICATION_CREDENTIALS),
          "GOOGLE_CREDENTIALS": $(has_var GOOGLE_CREDENTIALS),
          "CLOUDSDK_AUTH_ACCESS_TOKEN": $(has_var CLOUDSDK_AUTH_ACCESS_TOKEN),
          "USAGE_LENS_SYNTHETIC_PARENT_SECRET": $(has_var USAGE_LENS_SYNTHETIC_PARENT_SECRET)
        }
        EOF
        printf '{"time":\(nowEpoch),"data":{"usage":{"inputTokens":100000,"outputTokens":50000}}}\\n'
        """
        try script.write(to: fakeZstd, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZstd.path)

        let balBody = try JSONSerialization.data(withJSONObject: [
            "balance_infos": [["currency": "CNY", "total_balance": "9.99"]],
        ])
        let transport = MockNativeHTTPTransport(responses: [
            .success(NativeHTTPResponse(statusCode: 200, finalURL: DeepSeekNativeProbe.balanceURL, body: balBody)),
        ])

        var runnerBaseEnv = syntheticParentInjections
        runnerBaseEnv["HOME"] = tempDir.path
        runnerBaseEnv["PATH"] = "/usr/bin:/bin"
        let frozenBaseEnv = runnerBaseEnv

        let runner = ProbeRunner(
            deepSeekAPIKeyLoader: { "sk-keychain-deepseek-marker" },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { frozenBaseEnv },
            transport: transport,
            deepSeekZstdBinaryOverride: fakeZstd.path
        )

        let report = await runner.report(for: ProviderCatalog.deepseek)
        XCTAssertNil(report.failure, report.failure ?? "")
        XCTAssertEqual(report.envelope?.balance?.amount, 9.99)
        XCTAssertNotNil(report.envelope?.spend?.today, "fake zstd 应正常产出 events 花费估算")

        let observedData = try Data(contentsOf: reportFile)
        let observed = try XCTUnwrap(try JSONSerialization.jsonObject(with: observedData) as? [String: Bool])
        XCTAssertEqual(observed["PATH"], true, "子进程应保留最小 PATH")
        for forbiddenKey in syntheticParentInjections.keys {
            XCTAssertEqual(
                observed[forbiddenKey],
                false,
                "zstd 子进程绝不可见父环境或凭据变量 \(forbiddenKey)"
            )
        }
    }

    // MARK: - 缺陷 2：真实有界超时、非交互 Keychain 策略、zstd 看门狗与同步扫描取消

    func testSystemAgyKeychainQueryEnforcesNonInteractivePolicyAndExactTuple() {
        let query = SystemAgyKeychainReader.buildQuery(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "gemini")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "antigravity")
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertNotNil(context, "必须注入 LAContext 非交互策略")
        XCTAssertEqual(context?.interactionNotAllowed, true, "必须显式禁止阻塞式钥匙串交互弹窗")

        // 更新查询与属性同样必须严格限定精确元组、非交互策略且仅更新 kSecValueData（不改 ACL/标签/可访问性）
        let updateQuery = SystemAgyKeychainReader.buildUpdateQuery(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount
        )
        XCTAssertEqual(updateQuery[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(updateQuery[kSecAttrService as String] as? String, "gemini")
        XCTAssertEqual(updateQuery[kSecAttrAccount as String] as? String, "antigravity")
        XCTAssertNil(updateQuery[kSecMatchLimit as String], "SecItemUpdate 查询不得包含 kSecMatchLimit")
        XCTAssertNil(updateQuery[kSecReturnData as String], "SecItemUpdate 查询不得包含 kSecReturnData")
        let updateContext = updateQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertNotNil(updateContext)
        XCTAssertEqual(updateContext?.interactionNotAllowed, true)

        let payloadData = Data("{\"access_token\":\"synthetic\"}".utf8)
        let updateAttrs = SystemAgyKeychainReader.buildUpdateAttributes(payload: payloadData)
        XCTAssertEqual(updateAttrs.count, 1, "SecItemUpdate 仅允许更新 kSecValueData，绝不修改 ACL 或其他属性")
        XCTAssertEqual(updateAttrs[kSecValueData as String] as? Data, payloadData)

        // 非白名单元组与空载荷必须在调用 Security.framework 前即 fail-closed 拒绝
        let systemKC = SystemAgyKeychainReader()
        XCTAssertEqual(systemKC.readGenericPassword(service: "other", account: "antigravity"), .denied)
        XCTAssertEqual(systemKC.readGenericPassword(service: "gemini", account: "other"), .denied)
        XCTAssertEqual(systemKC.updateGenericPassword(service: "other", account: "antigravity", payload: "{}"), .rejected)
        XCTAssertEqual(systemKC.updateGenericPassword(service: "gemini", account: "other", payload: "{}"), .rejected)
        XCTAssertEqual(systemKC.updateGenericPassword(service: "gemini", account: "antigravity", payload: "   \n "), .rejected)
    }

    func testNonCooperativeKeychainWriteIsWallClockBoundedWithSingleFlightAndCancelBeforeAttach() async {
        final class SlowBlockingAgyKeychainWriter: AgyKeychainWriting, @unchecked Sendable {
            private let lock = NSLock()
            private let releaseSemaphore = DispatchSemaphore(value: 0)
            private let blockSeconds: TimeInterval
            private var _callCount = 0

            init(blockSeconds: TimeInterval = 3.0) {
                self.blockSeconds = blockSeconds
            }

            var callCount: Int { lock.withLock { _callCount } }
            func unblock() { releaseSemaphore.signal() }

            func updateGenericPassword(service: String, account: String, payload: String) -> AgyKeychainWriteResult {
                lock.withLock { _callCount += 1 }
                _ = releaseSemaphore.wait(timeout: .now() + blockSeconds)
                return .updated
            }
        }

        final class ImmediateAgyKeychainWriter: AgyKeychainWriting, @unchecked Sendable {
            private let lock = NSLock()
            private var _callCount = 0
            var callCount: Int { lock.withLock { _callCount } }

            func updateGenericPassword(service: String, account: String, payload: String) -> AgyKeychainWriteResult {
                lock.withLock { _callCount += 1 }
                return .updated
            }
        }

        // 1. 阻塞式 Keychain 写回必须真实墙钟超时，且共享单飞门控阻止并发读/写堆积阻塞线程
        let slowWriter = SlowBlockingAgyKeychainWriter(blockSeconds: 3.0)
        defer { slowWriter.unblock() }
        let immediateReader = ImmediateAgyKeychainReader(result: .missing)
        let boundedProbe = AgyNativeProbe(
            transport: MockNativeHTTPTransport(),
            keychain: immediateReader,
            keychainWriter: slowWriter,
            keychainTimeoutSeconds: 0.15
        )

        let t0 = Date()
        let writeRes1 = await boundedProbe.updateKeychainBoundedAsync(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount,
            payload: "{\"access_token\":\"synthetic\"}"
        )
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(writeRes1, .timeout)

        let t1 = Date()
        let writeRes2 = await boundedProbe.updateKeychainBoundedAsync(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount,
            payload: "{\"access_token\":\"synthetic-2\"}"
        )
        let readWhileWriteBlocked = await boundedProbe.readKeychainBoundedAsync(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount
        )
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.25)
        XCTAssertEqual(writeRes2, .timeout)
        XCTAssertEqual(readWhileWriteBlocked, .timeout)
        XCTAssertEqual(slowWriter.callCount, 1)
        XCTAssertEqual(immediateReader.callCount, 0)

        // 2. 确定性取消落在 register 与 attachTimer 之间：不得触发写入且必须归还单飞门控
        let immediateWriter = ImmediateAgyKeychainWriter()
        let cancelProbe = AgyNativeProbe(
            transport: MockNativeHTTPTransport(),
            keychain: ImmediateAgyKeychainReader(result: .missing),
            keychainWriter: immediateWriter,
            keychainTimeoutSeconds: 5.0
        )
        let hookReached = DispatchSemaphore(value: 0)
        let hookProceed = DispatchSemaphore(value: 0)
        let cancelTask = Task {
            await cancelProbe.updateKeychainBoundedAsync(
                service: AgyNativeProbe.keychainService,
                account: AgyNativeProbe.keychainAccount,
                payload: "{\"access_token\":\"synthetic-cancel\"}",
                onBeforeAttachTimer: {
                    hookReached.signal()
                    _ = hookProceed.wait(timeout: .now() + 2.0)
                }
            )
        }
        XCTAssertEqual(hookReached.wait(timeout: .now() + 2.0), .success)
        cancelTask.cancel()
        hookProceed.signal()
        let cancelledWrite = await cancelTask.value
        XCTAssertEqual(cancelledWrite, .timeout)
        XCTAssertEqual(immediateWriter.callCount, 0)

        let followUpWrite = await cancelProbe.updateKeychainBoundedAsync(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount,
            payload: "{\"access_token\":\"synthetic-after-cancel\"}"
        )
        XCTAssertEqual(followUpWrite, .updated)
        XCTAssertEqual(immediateWriter.callCount, 1)

        // 3. 非白名单元组在入口处即被拒绝
        let rejectedWrite = await cancelProbe.updateKeychainBoundedAsync(
            service: "other",
            account: AgyNativeProbe.keychainAccount,
            payload: "{\"access_token\":\"synthetic\"}"
        )
        XCTAssertEqual(rejectedWrite, .rejected)
        XCTAssertEqual(immediateWriter.callCount, 1)
    }

    func testNonCooperativeKeychainIsWallClockBoundedInProbeAndRunnerWithSingleFlight() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-kc-hang-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        // 1. AgyNativeProbe 自身有界 Keychain 超时 + 单飞防线程堆积
        let slowKC = SlowBlockingAgyKeychainReader(blockSeconds: 3.0)
        defer { slowKC.unblock() }

        let probe = AgyNativeProbe(
            transport: MockNativeHTTPTransport(),
            keychain: slowKC,
            realUserHomeOverride: tempHome,
            keychainTimeoutSeconds: 0.15
        )
        let wallStart1 = Date()
        let report1 = await probe.run(environment: ["HOME": tempHome.path])
        let wallElapsed1 = Date().timeIntervalSince(wallStart1)

        XCTAssertLessThan(wallElapsed1, 1.0, "阻塞型钥匙串调用必须在真实墙钟时间内超时返回，不得等待 3s")
        XCTAssertNil(report1.failure)
        XCTAssertTrue(report1.warnings.contains { $0.contains("钥匙串凭据超时") }, "warnings=\(report1.warnings)")

        // 第二次调用在第一次仍阻塞期间应立即 fail-closed（不额外堆积阻塞线程）
        let wallStart2 = Date()
        let report2 = await probe.run(environment: ["HOME": tempHome.path])
        let wallElapsed2 = Date().timeIntervalSince(wallStart2)
        XCTAssertLessThan(wallElapsed2, 0.25, "单飞门控应在上一查询卡死时立即 fail-closed")
        XCTAssertEqual(slowKC.callCount, 1, "卡死期间不得新起第二个阻塞钥匙串线程")
        XCTAssertTrue(report2.warnings.contains { $0.contains("钥匙串凭据超时") })

        // 2. ProbeRunner 外层 deadline 必须真实墙钟有界，不能被 withTaskGroup 等待不可协作子任务拖死
        let slowKC2 = SlowBlockingAgyKeychainReader(blockSeconds: 3.0)
        defer { slowKC2.unblock() }

        let runner = ProbeRunner(
            providerTimeouts: [ProviderCatalog.agy.id: 0.15],
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { ["HOME": tempHome.path] },
            transport: MockNativeHTTPTransport(),
            agyKeychain: slowKC2,
            realUserHomeOverride: tempHome,
            agyKeychainTimeout: 5.0
        )
        let runnerWallStart = Date()
        let runnerReport = await runner.report(for: ProviderCatalog.agy)
        let runnerWallElapsed = Date().timeIntervalSince(runnerWallStart)

        XCTAssertLessThan(runnerWallElapsed, 1.0, "ProbeRunner.report 必须在真实墙钟时间内返回，不得挂起等待子任务")
        XCTAssertNil(runnerReport.envelope)
        XCTAssertTrue(runnerReport.failure?.contains("探针超时") ?? false, runnerReport.failure ?? "nil")
    }

    func testDeepSeekZstdWatchdogSIGKILLEscalationReapExitValidationAndBudget() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("usage-lens-zstd-wd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let dummyInput = tempDir.appendingPathComponent("session.v4.jsonl.zstd")
        try Data("dummy".utf8).write(to: dummyInput)

        // 1. 忽略 SIGTERM 的卡死子进程 -> 必须升级 SIGKILL 并确认回收
        let pidFile = tempDir.appendingPathComponent("stuck.pid")
        let stuckScript = tempDir.appendingPathComponent("zstd-stuck.sh")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFile.path)"
        sleep 30
        """.write(to: stuckScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuckScript.path)

        let probe = DeepSeekNativeProbe(
            transport: MockNativeHTTPTransport(),
            zstdBinaryOverride: stuckScript.path,
            zstdTimeoutSeconds: 1.0,
            spendScanBudgetSeconds: 2.0
        )
        let wallStart = Date()
        let stuckOutcome = await probe.decompressZstd(
            at: dummyInput,
            zstdBin: stuckScript.path,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.8
        )
        let wallElapsed = Date().timeIntervalSince(wallStart)

        XCTAssertLessThan(wallElapsed, 2.5, "卡死 zstd 必须在超时 + SIGTERM 宽限 + SIGKILL 后立即返回")
        XCTAssertNil(stuckOutcome.text)
        XCTAssertTrue(stuckOutcome.timedOut)
        XCTAssertTrue(stuckOutcome.escalatedToSIGKILL, "忽略 SIGTERM 时必须升级到 SIGKILL")
        XCTAssertTrue(stuckOutcome.reaped, "必须确认子进程已被回收")

        if let pidStr = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            XCTAssertNotEqual(kill(pid, 0), 0, "回收后子进程 PID 不应继续存活")
        } else {
            XCTFail("未能读取卡死测试子进程 PID")
        }

        // 2. 非零退出码必须 fail-closed 拒绝解析 stdout
        let nonzeroScript = tempDir.appendingPathComponent("zstd-nonzero.sh")
        try """
        #!/bin/sh
        printf '{"time":1763200000,"data":{"usage":{"inputTokens":500,"outputTokens":100}}}\\n'
        exit 2
        """.write(to: nonzeroScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonzeroScript.path)

        let nonzeroProbe = DeepSeekNativeProbe(
            transport: MockNativeHTTPTransport(),
            zstdBinaryOverride: nonzeroScript.path,
            zstdTimeoutSeconds: 5.0,
            spendScanBudgetSeconds: 5.0
        )
        let nonzeroOutcome = await nonzeroProbe.decompressZstd(
            at: dummyInput,
            zstdBin: nonzeroScript.path,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5.0
        )
        XCTAssertNil(nonzeroOutcome.text, "非零退出码输出绝不可被当作有效解压内容")
        XCTAssertEqual(nonzeroOutcome.exitStatus, 2)
        XCTAssertTrue(nonzeroOutcome.reaped)

        // 3. 解压输出超过字节上限时立刻中止并回收子进程
        let floodScript = tempDir.appendingPathComponent("zstd-flood.sh")
        try """
        #!/bin/sh
        head -c 262144 /dev/zero | tr '\\0' 'A'
        """.write(to: floodScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: floodScript.path)

        let cappedProbe = DeepSeekNativeProbe(
            transport: MockNativeHTTPTransport(),
            zstdBinaryOverride: floodScript.path,
            zstdTimeoutSeconds: 5.0,
            spendScanBudgetSeconds: 5.0,
            zstdMaxDecompressedBytes: 4096
        )
        let overflowOutcome = await cappedProbe.decompressZstd(
            at: dummyInput,
            zstdBin: floodScript.path,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5.0
        )
        XCTAssertNil(overflowOutcome.text)
        XCTAssertTrue(overflowOutcome.overflowed, "超过解压字节上限必须立即中止")
        XCTAssertTrue(overflowOutcome.reaped)

        // 4. 扫描总预算必须约束单个卡死 zstd 子进程，不能放任其跑到 10s
        let homeWithSessions = tempDir.appendingPathComponent("budget-home", isDirectory: true)
        for idx in 1...3 {
            let sDir = homeWithSessions.appendingPathComponent(".dsh/sessions/s\(idx)", isDirectory: true)
            try fm.createDirectory(at: sDir, withIntermediateDirectories: true)
            try Data("dummy".utf8).write(to: sDir.appendingPathComponent("session.v4.jsonl.zstd"))
        }
        let budgetProbe = DeepSeekNativeProbe(
            transport: MockNativeHTTPTransport(),
            zstdBinaryOverride: stuckScript.path,
            zstdTimeoutSeconds: 10.0,
            spendScanBudgetSeconds: 0.3
        )
        let budgetStart = Date()
        let budgetReport = await budgetProbe.run(environment: ["HOME": homeWithSessions.path, "PATH": "/usr/bin:/bin"])
        let budgetElapsed = Date().timeIntervalSince(budgetStart)
        XCTAssertLessThan(budgetElapsed, 2.0, "总扫描预算必须传入并限制每个 zstd 子进程，不得等待 10s")
        XCTAssertNil(budgetReport.envelope?.spend)

        // 5. ProbeRunner 外层超时必须立即返回并触发取消链，不得被 10s 卡死 zstd 拖住
        let runner = ProbeRunner(
            timeout: 0.35,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { ["HOME": homeWithSessions.path, "PATH": "/usr/bin:/bin"] },
            transport: MockNativeHTTPTransport(),
            deepSeekZstdBinaryOverride: stuckScript.path,
            deepSeekZstdTimeout: 10.0,
            deepSeekScanBudget: 10.0
        )
        let runnerStart = Date()
        let runnerReport = await runner.report(for: ProviderCatalog.deepseek)
        let runnerElapsed = Date().timeIntervalSince(runnerStart)
        XCTAssertLessThan(runnerElapsed, 1.5, "ProbeRunner 必须在真实墙钟时间内超时返回")
        XCTAssertTrue(runnerReport.failure?.contains("探针超时") ?? false, runnerReport.failure ?? "nil")
    }

    func testSynchronousScanHonorsCancellationPromptly() throws {
        let fm = FileManager.default
        let tempFile = fm.temporaryDirectory.appendingPathComponent("usage-lens-cancel-scan-\(UUID().uuidString).jsonl")
        let line = String(repeating: "x", count: 1024) + "\n"
        let payload = String(repeating: line, count: 600) // ~600 KB
        try payload.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tempFile) }

        var checks = 0
        let (lines, _) = try NativeProbeSupport.readLinesReverse(
            at: tempFile,
            maxBytes: 1_048_576,
            chunkSize: 4096,
            shouldCancel: {
                checks += 1
                return checks > 2
            }
        )
        XCTAssertTrue(lines.isEmpty, "协作取消触发后应立刻中止大文件回扫并返回空结果")
        XCTAssertLessThanOrEqual(checks, 4, "取消后不得继续扫描剩余块")
    }

    // MARK: - 缺陷 3：真实 URLSession 流式 1MB 上限、即时取消与禁止重定向测试

    func testPinnedURLSessionRejectsOversizedDeclaredContentLengthBeforeBufferingBody() async {
        StreamingMockRegistry.shared.configure(
            .declaredOversized(contentLength: "5242880", totalChunks: 80, chunkSize: 65_536)
        )
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let request = NativeHTTPRequest(
            url: AgyNativeProbe.loadCodeAssistURL,
            method: "POST",
            headers: ["Authorization": "Bearer ya29.synthetic_stream_test"],
            expectedHost: AgyNativeProbe.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )

        do {
            _ = try await transport.send(request)
            XCTFail("超过 1MB 的声明 Content-Length 必须被拒绝")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .responseTooLarge(declaredBytes: 5_242_880))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        let snap = StreamingMockRegistry.shared.state.snapshot()
        XCTAssertEqual(snap.chunks, 0, "应在响应头阶段即取消，绝不读取或缓冲响应体")
        XCTAssertTrue(snap.stopped, "URLSession 任务应立即取消")
    }

    func testPinnedURLSessionRejectsOverflowingContentLengthHeader() async {
        StreamingMockRegistry.shared.configure(
            .declaredOversized(contentLength: "99999999999999999999999999999", totalChunks: 4, chunkSize: 1024)
        )
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let request = NativeHTTPRequest(
            url: CodexNativeProbe.usageURL,
            method: "GET",
            expectedHost: CodexNativeProbe.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )

        do {
            _ = try await transport.send(request)
            XCTFail("溢出 Int64 的超大 Content-Length 必须被拒绝")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .responseTooLarge(declaredBytes: nil))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let snap = StreamingMockRegistry.shared.state.snapshot()
        XCTAssertEqual(snap.chunks, 0)
        XCTAssertTrue(snap.stopped)
    }

    func testPinnedURLSessionCancelsOversizedChunkedStreamAtCapWithoutBufferingWholeBody() async {
        // 256 * 64KB = 16MB 无 Content-Length 分块流，应在刚超过 1MB 时立刻取消
        StreamingMockRegistry.shared.configure(
            .chunkedStream(totalChunks: 256, chunkSize: 65_536, chunkDelayMs: 2)
        )
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let request = NativeHTTPRequest(
            url: AgyNativeProbe.retrieveQuotaURL,
            method: "POST",
            expectedHost: AgyNativeProbe.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )

        do {
            _ = try await transport.send(request)
            XCTFail("超过 1MB 的分块响应必须在流式接收时中止")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .responseTooLarge(declaredBytes: nil))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }

        // 等极短时间让 stopLoading 回调可见
        try? await Task.sleep(nanoseconds: 30_000_000)
        let snap = StreamingMockRegistry.shared.state.snapshot()
        XCTAssertTrue(snap.stopped, "超出 1MB 时必须立刻取消底层 URLSessionDataTask")
        XCTAssertLessThan(
            snap.bytes,
            3 * NativeProbeSupport.httpMaxBytes,
            "流式超限必须在刚越过 1MB 时截断，远小于 16MB 总流大小（实际发送 \(snap.bytes) 字节）"
        )
    }

    func testPinnedURLSessionChunkedExactCapBoundaryAndOneByteOver() async throws {
        // 恰好 1MB (16 * 65536 = 1,048,576) 必须放行
        StreamingMockRegistry.shared.configure(
            .chunkedStream(totalChunks: 16, chunkSize: 65_536, chunkDelayMs: 0)
        )
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let okRequest = NativeHTTPRequest(
            url: GeminiNativeProbe.retrieveQuotaURL,
            method: "POST",
            expectedHost: GeminiNativeProbe.officialHost,
            maxBytes: NativeProbeSupport.httpMaxBytes
        )
        let okResp = try await transport.send(okRequest)
        XCTAssertEqual(okResp.statusCode, 200)
        XCTAssertEqual(okResp.body.count, NativeProbeSupport.httpMaxBytes)

        // 恰好 1MB + 1 字节 (使用 1024 + 1 测试精确边界) 必须拒绝
        StreamingMockRegistry.shared.configure(
            .chunkedStream(totalChunks: 1, chunkSize: 1025, chunkDelayMs: 0)
        )
        let overRequest = NativeHTTPRequest(
            url: GeminiNativeProbe.retrieveQuotaURL,
            method: "POST",
            expectedHost: GeminiNativeProbe.officialHost,
            maxBytes: 1024
        )
        do {
            _ = try await transport.send(overRequest)
            XCTFail("超出 maxBytes 1 字节必须拒绝")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .responseTooLarge(declaredBytes: nil))
        }
    }

    func testPinnedURLSessionRejectsRedirectsWithoutFollowingOrLeakingHeaders() async {
        let evilTarget = URL(string: "https://evil.example.com/steal-token")!
        StreamingMockRegistry.shared.configure(.redirectWithLocation(statusCode: 302, target: evilTarget))
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let request = NativeHTTPRequest(
            url: CodexNativeProbe.usageURL,
            method: "GET",
            headers: ["Authorization": "Bearer sk-must-not-redirect"],
            expectedHost: CodexNativeProbe.officialHost
        )

        do {
            _ = try await transport.send(request)
            XCTFail("302 重定向必须被拒绝")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .redirected(statusCode: 302))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }

        let snap = StreamingMockRegistry.shared.state.snapshot()
        XCTAssertEqual(snap.requestsStarted, 1, "绝不可向重定向目标发起第二次请求")
        XCTAssertFalse(snap.urls.contains(evilTarget), "绝不可访问重定向目标域名")

        // 无 Location 的直接 307 响应同样必须拒绝
        StreamingMockRegistry.shared.configure(.redirectDirect(statusCode: 307))
        do {
            _ = try await transport.send(request)
            XCTFail("307 重定向必须被拒绝")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .redirected(statusCode: 307))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }
    }

    func testPinnedURLSessionTaskCancellationStopsActiveStreamPromptly() async {
        StreamingMockRegistry.shared.configure(.infiniteSlowStream)
        let transport = PinnedURLSessionTransport(protocolClasses: [StreamingMockURLProtocol.self])
        let request = NativeHTTPRequest(
            url: DeepSeekNativeProbe.balanceURL,
            method: "GET",
            timeout: 10.0,
            expectedHost: DeepSeekNativeProbe.officialHost
        )

        let wallStart = Date()
        let task = Task {
            try await transport.send(request)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("被取消的请求不应成功")
        } catch let error as NativeHTTPError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            // CancellationError 也可接受
        }

        let wallElapsed = Date().timeIntervalSince(wallStart)
        XCTAssertLessThan(wallElapsed, 1.0, "Task 取消应立刻中断底层 URLSessionDataTask")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(StreamingMockRegistry.shared.state.snapshot().stopped)
    }

    // MARK: - 缺陷 4：安全数值转换、防溢出累加与原生解析路径边界回归测试

    func testCheckedNumericConversionAndOverflowBoundariesNeverTrap() {
        // 合法边界
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt(0), 0)
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt(42), 42)
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt(Int.max), Int.max)
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt("\(Int.max)"), Int.max)
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt(123.9), 123)
        XCTAssertEqual(NativeProbeSupport.nonNegativeInt(" 987.6 "), 987)

        // 非法 / 溢出 / 极端 Double / UInt64 边界（绝不 trap）
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(-1))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt("-5"))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(true))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(NSNumber(value: true)))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(Double.nan))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(Double.infinity))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(-Double.infinity))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(1e100))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt("1e100"))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(Double(Int.max))) // IEEE-754 向上舍入到 2^63
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(Double.greatestFiniteMagnitude))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(NSNumber(value: UInt64(Int.max) + 1)))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt(NSNumber(value: UInt64.max)))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt("9223372036854775808"))
        XCTAssertNil(NativeProbeSupport.nonNegativeInt("999999999999999999999999999"))

        // 窗口时长乘法防溢出
        XCTAssertEqual(NativeProbeSupport.checkedPositiveIntSeconds(18_000, multiplier: 1.0), 18_000)
        XCTAssertEqual(NativeProbeSupport.checkedPositiveIntSeconds(300, multiplier: 60.0), 18_000)
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(1e100, multiplier: 1.0))
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(1e308, multiplier: 60.0))
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(Double.greatestFiniteMagnitude, multiplier: 60.0))
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(1e20, multiplier: 60.0))
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(0, multiplier: 60.0))
        XCTAssertNil(NativeProbeSupport.checkedPositiveIntSeconds(-10, multiplier: 60.0))

        // 防溢出加法
        XCTAssertEqual(NativeProbeSupport.checkedAdd(Int.max, 0), Int.max)
        XCTAssertNil(NativeProbeSupport.checkedAdd(Int.max, 1))
        XCTAssertNil(NativeProbeSupport.checkedAdd(Int.max - 10, 20))

        // humanAge 与 ProbeContract 极端数值绝不 trap
        XCTAssertEqual(NativeProbeSupport.humanAge(seconds: 1e100), "很久以前")
        XCTAssertEqual(NativeProbeSupport.humanAge(seconds: .infinity), "很久以前")
        XCTAssertEqual(NativeProbeSupport.humanAge(seconds: .nan), "很久以前")

        let extremeEnvelopeJSON = """
        {"schema":"usage-lens/probe@1","provider":"codex","windows":[{"id":"5h","window_seconds":1e100}],"usage":{"today_tokens":1e100}}
        """
        let decoded = ProbeJSON.decode(extremeEnvelopeJSON)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.windows.first?.windowSeconds)
        XCTAssertNil(decoded?.usage?.todayTokens)
    }

    func testAgyNativeTranscriptExtremeAndOverflowTokensDoNotTrap() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-agy-overflow-\(UUID().uuidString)", isDirectory: true)
        let logDir = tempHome.appendingPathComponent(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let transcriptURL = logDir.appendingPathComponent("transcript.jsonl")

        // 1. 含 1e100 畸形记录 + 一条正常记录 -> 不崩溃、跳过畸形记录、产出诊断警告并保留正常值
        let mixed = """
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":1e100,"output_tokens":10}
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":300,"output_tokens":200}
        """
        try mixed.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let probe = AgyNativeProbe(transport: MockNativeHTTPTransport())
        let mixedReport = await probe.run(environment: ["HOME": tempHome.path, "AGY_DISABLE_LOCAL_AUTH": "1"], now: now)
        XCTAssertNil(mixedReport.failure)
        XCTAssertEqual(mixedReport.envelope?.usage?.todayTokens, 500)
        XCTAssertTrue(mixedReport.warnings.contains { $0.contains("异常或溢出") }, "warnings=\(mixedReport.warnings)")

        // 2. 单条记录内部相加溢出 Int.max -> 不崩溃、置空 todayTokens 并产出溢出警告
        let innerOverflow = """
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":9223372036854775807,"output_tokens":10}
        """
        try innerOverflow.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let innerReport = await probe.run(environment: ["HOME": tempHome.path, "AGY_DISABLE_LOCAL_AUTH": "1"], now: now)
        XCTAssertNil(innerReport.failure)
        XCTAssertNil(innerReport.envelope?.usage?.todayTokens)
        XCTAssertTrue(innerReport.warnings.contains { $0.contains("超出整数上限") }, "warnings=\(innerReport.warnings)")

        // 3. 跨记录累加溢出 Int.max -> 不崩溃、置空 todayTokens 并产出溢出警告
        let sumOverflow = """
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":9223372036854775800}
        {"type":"PLANNER_RESPONSE","created_at":"\(iso)","input_tokens":9223372036854775800}
        """
        try sumOverflow.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let sumReport = await probe.run(environment: ["HOME": tempHome.path, "AGY_DISABLE_LOCAL_AUTH": "1"], now: now)
        XCTAssertNil(sumReport.failure)
        XCTAssertNil(sumReport.envelope?.usage?.todayTokens)
        XCTAssertTrue(sumReport.warnings.contains { $0.contains("超出整数上限") }, "warnings=\(sumReport.warnings)")
    }

    func testCodexNativeExtremeDurationsAndOverflowTokensDoNotTrap() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-codex-overflow-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = tempHome.appendingPathComponent(".codex/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let futureEpoch = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        let rolloutURL = sessionsDir.appendingPathComponent("rollout-2026-11-22.jsonl")

        // 1. Live API 返回极端 limit_window_seconds=1e100 与 window_minutes=1e308（乘法溢出到 inf）
        let liveBody = try JSONSerialization.data(withJSONObject: [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 40, "limit_window_seconds": 1e100, "reset_at": futureEpoch],
                "secondary_window": ["used_percent": 20, "window_minutes": 1e308, "reset_at": futureEpoch + 86_400],
            ],
        ])
        let liveTransport = MockNativeHTTPTransport(responses: [
            .success(NativeHTTPResponse(statusCode: 200, finalURL: CodexNativeProbe.usageURL, body: liveBody)),
        ])
        let liveReport = await CodexNativeProbe(transport: liveTransport).run(
            environment: ["HOME": tempHome.path, "CODEX_ACCESS_TOKEN": "sk-synthetic-codex-overflow-test"],
            now: now
        )
        XCTAssertNil(liveReport.failure)
        XCTAssertEqual(liveReport.envelope?.windows.first(where: { $0.id == "5h" })?.windowSeconds, 18_000)
        XCTAssertEqual(liveReport.envelope?.windows.first(where: { $0.id == "7d" })?.windowSeconds, 604_800)
        XCTAssertTrue(liveReport.warnings.contains { $0.contains("窗口时长数值异常") }, "warnings=\(liveReport.warnings)")

        // 2. 本地 rollout 日志含 total_tokens=1e100 + 合法记录，以及 window_minutes=1e308 / 1e25
        let mixedRollout = """
        {"timestamp":"\(iso)","type":"token_usage_record","payload":{"usage":{"total_tokens":1e100}}}
        {"timestamp":"\(iso)","type":"token_usage_record","payload":{"usage":{"total_tokens":1200}}}
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":35,"window_minutes":1e308,"resets_at":\(futureEpoch)},"secondary":{"used_percent":12,"window_minutes":1e25,"resets_at":\(futureEpoch + 86400)}}}}
        """
        try mixedRollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let localReport = await CodexNativeProbe(transport: MockNativeHTTPTransport()).run(
            environment: ["HOME": tempHome.path],
            now: now
        )
        XCTAssertNil(localReport.failure)
        XCTAssertEqual(localReport.envelope?.usage?.todayTokens, 1200)
        XCTAssertEqual(localReport.envelope?.windows.first(where: { $0.id == "5h" })?.windowSeconds, 18_000)
        XCTAssertEqual(localReport.envelope?.windows.first(where: { $0.id == "7d" })?.windowSeconds, 604_800)
        XCTAssertTrue(localReport.warnings.contains { $0.contains("异常或溢出") }, "warnings=\(localReport.warnings)")
        XCTAssertTrue(localReport.warnings.contains { $0.contains("窗口时长数值异常") }, "warnings=\(localReport.warnings)")

        // 3. 本地 rollout 两条合法大额 token 累加溢出 Int.max -> 不崩溃、置空并输出溢出警告
        let overflowRollout = """
        {"timestamp":"\(iso)","type":"token_usage_record","payload":{"usage":{"total_tokens":9223372036854775800}}}
        {"timestamp":"\(iso)","type":"token_usage_record","payload":{"usage":{"total_tokens":9223372036854775800}}}
        """
        try overflowRollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let overflowReport = await CodexNativeProbe(transport: MockNativeHTTPTransport()).run(
            environment: ["HOME": tempHome.path],
            now: now
        )
        XCTAssertNil(overflowReport.failure)
        XCTAssertNil(overflowReport.envelope?.usage?.todayTokens)
        XCTAssertTrue(overflowReport.warnings.contains { $0.contains("超出整数上限") }, "warnings=\(overflowReport.warnings)")
    }

    // MARK: - 缺陷 5：DispatchSourceTimer 生命周期安全（先完成/先取消再挂载、超时路径、并发竞态）

    func testProbeContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout() async {
        // 1. 完成先于 attachTimer：定时器必须被安全 cancel + activate 后释放，且事件回调绝不触发
        let completionEventFired = AtomicCounter()
        let completionCancelSem = DispatchSemaphore(value: 0)
        let completionWorkTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        defer { completionWorkTask.cancel() }

        let completionReport = await withCheckedContinuation { (cont: CheckedContinuation<ProbeReport, Never>) in
            let once = LockedOnceProbeContinuation(cont)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now())
            timer.setEventHandler {
                completionEventFired.increment()
                once.finish(
                    with: ProbeReport(provider: ProviderCatalog.opencode, failure: "不应触发超时"),
                    cancelWork: true
                )
            }
            timer.setCancelHandler {
                completionCancelSem.signal()
            }

            // 模拟极快操作在 attachTimer 前已收敛
            once.finish(
                with: ProbeReport(provider: ProviderCatalog.opencode, failure: nil, isMissingProbe: true),
                cancelWork: false
            )
            let attached = once.attachTimer(timer)
            XCTAssertFalse(attached, "已收敛后 attachTimer 必须返回 false 并安全激活释放定时器")
            once.attachWorkTask(completionWorkTask)
        }
        XCTAssertTrue(completionReport.isMissingProbe)
        XCTAssertNil(completionReport.failure)
        XCTAssertEqual(
            completionCancelSem.wait(timeout: .now() + 2.0),
            .success,
            "已收敛路径必须激活一次以触发 libdispatch 正常 cancel/释放流程"
        )
        XCTAssertEqual(completionEventFired.value, 0, "预取消的定时器事件回调绝不可触发")
        XCTAssertFalse(completionWorkTask.isCancelled, "正常完成(cancelWork=false)不应误取消 workTask")

        // 2. 取消先于 attachTimer：LockedProbeRunBox.cancel 先收敛，attachTimer 必须安全释放定时器并取消 workTask
        let cancelEventFired = AtomicCounter()
        let cancelHandlerSem = DispatchSemaphore(value: 0)
        let cancelledWorkTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        defer { cancelledWorkTask.cancel() }

        let cancelledReport = await withCheckedContinuation { (cont: CheckedContinuation<ProbeReport, Never>) in
            let box = LockedProbeRunBox()
            let once = LockedOnceProbeContinuation(cont)
            XCTAssertTrue(box.register(once))

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now())
            timer.setEventHandler {
                cancelEventFired.increment()
                once.finish(
                    with: ProbeReport(provider: ProviderCatalog.agy, failure: "不应触发超时"),
                    cancelWork: true
                )
            }
            timer.setCancelHandler {
                cancelHandlerSem.signal()
            }

            // 模拟外部任务取消落在 register 与 attachTimer 之间
            box.cancel(provider: ProviderCatalog.agy, started: Date())
            let attached = once.attachTimer(timer)
            XCTAssertFalse(attached, "取消先于挂载时 attachTimer 必须返回 false 并安全激活释放定时器")
            once.attachWorkTask(cancelledWorkTask)
        }
        XCTAssertEqual(cancelledReport.failure, "探针已取消")
        XCTAssertEqual(
            cancelHandlerSem.wait(timeout: .now() + 2.0),
            .success,
            "取消先于挂载时必须激活一次以完成安全销毁"
        )
        XCTAssertEqual(cancelEventFired.value, 0, "已取消定时器的事件回调绝不可触发")
        XCTAssertTrue(cancelledWorkTask.isCancelled, "取消先于 attachWorkTask 时仍必须取消 workTask")

        // 3. 活跃看门狗超时路径 + 重复 attachTimer 防护 + 迟到完成忽略
        let timeoutCancelSem = DispatchSemaphore(value: 0)
        let dupTimerEventFired = AtomicCounter()
        let dupTimerCancelSem = DispatchSemaphore(value: 0)
        let slowWorkTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        defer { slowWorkTask.cancel() }

        var capturedOnce: LockedOnceProbeContinuation?
        let wallStart = Date()
        let timeoutReport = await withCheckedContinuation { (cont: CheckedContinuation<ProbeReport, Never>) in
            let once = LockedOnceProbeContinuation(cont)
            capturedOnce = once

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + .milliseconds(60))
            timer.setEventHandler {
                once.finish(
                    with: ProbeReport(provider: ProviderCatalog.agy, failure: "探针超时（>0.1s）"),
                    cancelWork: true
                )
            }
            timer.setCancelHandler {
                timeoutCancelSem.signal()
            }
            XCTAssertTrue(once.attachTimer(timer))

            // 重复挂载第二个定时器必须被安全拒收并激活释放
            let dupTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            dupTimer.schedule(deadline: .now())
            dupTimer.setEventHandler {
                dupTimerEventFired.increment()
            }
            dupTimer.setCancelHandler {
                dupTimerCancelSem.signal()
            }
            XCTAssertFalse(once.attachTimer(dupTimer))

            once.attachWorkTask(slowWorkTask)
        }
        let elapsed = Date().timeIntervalSince(wallStart)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertTrue(timeoutReport.failure?.contains("探针超时") ?? false, timeoutReport.failure ?? "nil")
        XCTAssertTrue(slowWorkTask.isCancelled, "看门狗超时必须取消关联 workTask")
        XCTAssertEqual(timeoutCancelSem.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(dupTimerCancelSem.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(dupTimerEventFired.value, 0)

        // 迟到完成绝不可二次 resume 或崩溃
        capturedOnce?.finish(
            with: ProbeReport(provider: ProviderCatalog.agy, failure: "late"),
            cancelWork: false
        )
    }

    func testKeychainContinuationTimerLifetimeCompletionAndCancelBeforeAttachAndTimeout() async {
        // 1. 完成先于 attachTimer
        let completionEventFired = AtomicCounter()
        let completionCancelSem = DispatchSemaphore(value: 0)
        let completionResult = await withCheckedContinuation { (cont: CheckedContinuation<AgyKeychainReadResult, Never>) in
            let once = LockedKeychainContinuation(cont)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now())
            timer.setEventHandler {
                completionEventFired.increment()
                once.finish(with: .timeout)
            }
            timer.setCancelHandler {
                completionCancelSem.signal()
            }

            once.finish(with: .payload("synthetic-kc-payload"))
            XCTAssertFalse(once.attachTimer(timer))
        }
        XCTAssertEqual(completionResult, .payload("synthetic-kc-payload"))
        XCTAssertEqual(completionCancelSem.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(completionEventFired.value, 0)

        // 2. 取消先于 attachTimer
        let cancelEventFired = AtomicCounter()
        let cancelHandlerSem = DispatchSemaphore(value: 0)
        let cancelledResult = await withCheckedContinuation { (cont: CheckedContinuation<AgyKeychainReadResult, Never>) in
            let box = LockedKeychainCancelBox()
            let once = LockedKeychainContinuation(cont)
            XCTAssertTrue(box.register(once))

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now())
            timer.setEventHandler {
                cancelEventFired.increment()
                once.finish(with: .denied)
            }
            timer.setCancelHandler {
                cancelHandlerSem.signal()
            }

            box.cancel()
            XCTAssertFalse(once.attachTimer(timer))
        }
        XCTAssertEqual(cancelledResult, .timeout)
        XCTAssertEqual(cancelHandlerSem.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(cancelEventFired.value, 0)

        // 3. 活跃看门狗超时路径 + 迟到结果忽略
        let timeoutCancelSem = DispatchSemaphore(value: 0)
        var capturedOnce: LockedKeychainContinuation?
        let wallStart = Date()
        let timeoutResult = await withCheckedContinuation { (cont: CheckedContinuation<AgyKeychainReadResult, Never>) in
            let once = LockedKeychainContinuation(cont)
            capturedOnce = once

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + .milliseconds(60))
            timer.setEventHandler {
                once.finish(with: .timeout)
            }
            timer.setCancelHandler {
                timeoutCancelSem.signal()
            }
            XCTAssertTrue(once.attachTimer(timer))
        }
        XCTAssertLessThan(Date().timeIntervalSince(wallStart), 1.0)
        XCTAssertEqual(timeoutResult, .timeout)
        XCTAssertEqual(timeoutCancelSem.wait(timeout: .now() + 2.0), .success)
        capturedOnce?.finish(with: .payload("late-payload"))
    }

    func testProbeRunnerAndKeychainEndToEndDeterministicCancelBeforeAttachAndFastCompletion() async {
        let runner = ProbeRunner(transport: MockNativeHTTPTransport())

        // 1. ProbeRunner.runWithTimeout：确定性取消落在 register 与 attachTimer 之间
        let runnerHookReached = DispatchSemaphore(value: 0)
        let runnerHookProceed = DispatchSemaphore(value: 0)
        let runnerOpStarted = AtomicCounter()
        let cancelBeforeAttachTask = Task {
            await runner.runWithTimeout(
                seconds: 5.0,
                provider: ProviderCatalog.agy,
                started: Date(),
                onBeforeAttachTimer: {
                    runnerHookReached.signal()
                    _ = runnerHookProceed.wait(timeout: .now() + 2.0)
                },
                operation: {
                    runnerOpStarted.increment()
                    return ProbeReport(provider: ProviderCatalog.agy, failure: nil)
                }
            )
        }
        XCTAssertEqual(runnerHookReached.wait(timeout: .now() + 2.0), .success)
        cancelBeforeAttachTask.cancel()
        runnerHookProceed.signal()
        let cancelledRunnerReport = await cancelBeforeAttachTask.value
        XCTAssertEqual(cancelledRunnerReport.failure, "探针已取消")
        XCTAssertEqual(runnerOpStarted.value, 0, "挂载定时器前已取消时不得再启动 detached operation")

        // 2. ProbeRunner.runWithTimeout：极快操作（模拟 OpenCode）在 attachWorkTask 前已完成，看门狗必须已先激活并安全取消
        let fastOpCompleted = DispatchSemaphore(value: 0)
        let fastReport = await runner.runWithTimeout(
            seconds: 5.0,
            provider: ProviderCatalog.opencode,
            started: Date(),
            onBeforeAttachWorkTask: {
                _ = fastOpCompleted.wait(timeout: .now() + 2.0)
            },
            operation: {
                let r = ProbeReport(
                    provider: ProviderCatalog.opencode,
                    failure: "未安装原生探针 opencode",
                    isMissingProbe: true
                )
                fastOpCompleted.signal()
                return r
            }
        )
        XCTAssertTrue(fastReport.isMissingProbe)
        XCTAssertEqual(fastReport.failure, "未安装原生探针 opencode")

        // 3. ProbeRunner.runWithTimeout：超时发生在 attachWorkTask 之前，attachWorkTask 仍必须取消 workTask
        let delayedWorkObservedCancel = DispatchSemaphore(value: 0)
        let timeoutBeforeAttachWorkReport = await runner.runWithTimeout(
            seconds: 0.06,
            provider: ProviderCatalog.agy,
            started: Date(),
            onBeforeAttachWorkTask: {
                usleep(140_000)
            },
            operation: {
                for _ in 0..<100 {
                    if Task.isCancelled {
                        delayedWorkObservedCancel.signal()
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return ProbeReport(provider: ProviderCatalog.agy, failure: "should-not-win")
            }
        )
        XCTAssertTrue(timeoutBeforeAttachWorkReport.failure?.contains("探针超时") ?? false)
        XCTAssertEqual(
            delayedWorkObservedCancel.wait(timeout: .now() + 2.0),
            .success,
            "超时早于 attachWorkTask 时，attachWorkTask 仍必须取消已派发的工作任务"
        )

        // 4. AgyNativeProbe.readKeychainBoundedAsync：确定性取消落在 register 与 attachTimer 之间，
        //    不得触发 Keychain 读取且必须归还单飞门控（后续查询立即可用）
        let immediateKC = ImmediateAgyKeychainReader(result: .payload("{\"access_token\":\"synthetic-after-cancel\"}"))
        let agyProbe = AgyNativeProbe(
            transport: MockNativeHTTPTransport(),
            keychain: immediateKC,
            keychainTimeoutSeconds: 5.0
        )
        let kcHookReached = DispatchSemaphore(value: 0)
        let kcHookProceed = DispatchSemaphore(value: 0)
        let kcCancelTask = Task {
            await agyProbe.readKeychainBoundedAsync(
                service: AgyNativeProbe.keychainService,
                account: AgyNativeProbe.keychainAccount,
                onBeforeAttachTimer: {
                    kcHookReached.signal()
                    _ = kcHookProceed.wait(timeout: .now() + 2.0)
                }
            )
        }
        XCTAssertEqual(kcHookReached.wait(timeout: .now() + 2.0), .success)
        kcCancelTask.cancel()
        kcHookProceed.signal()
        let kcCancelledResult = await kcCancelTask.value
        XCTAssertEqual(kcCancelledResult, .timeout)
        XCTAssertEqual(immediateKC.callCount, 0, "挂载定时器前已取消时不得派发阻塞式 Keychain 读取")

        let followUpResult = await agyProbe.readKeychainBoundedAsync(
            service: AgyNativeProbe.keychainService,
            account: AgyNativeProbe.keychainAccount
        )
        XCTAssertEqual(followUpResult, .payload("{\"access_token\":\"synthetic-after-cancel\"}"))
        XCTAssertEqual(immediateKC.callCount, 1, "单飞门控在取消路径必须准确归还，不得泄漏锁定")
    }

    func testConcurrentTimerLifetimeStressForProbeRunnerAndAgyKeychain() async {
        // 1. 高频并发：OpenCode 极速返回 + 外部取消 + 极短超时竞态（覆盖生产 ProbeRunner 全链路）
        let runner = ProbeRunner(
            timeout: 0.5,
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { [:] },
            transport: MockNativeHTTPTransport()
        )
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask {
                    let task = Task {
                        await runner.report(for: ProviderCatalog.opencode)
                    }
                    if i % 3 == 0 {
                        task.cancel()
                    }
                    let report = await task.value
                    XCTAssertEqual(report.provider.id, ProviderCatalog.opencode.id)
                    XCTAssertTrue(report.isMissingProbe || report.failure == "探针已取消")
                }
            }
        }

        // 2. 高频并发：直接对 LockedOnceProbeContinuation 与 LockedKeychainContinuation 做多线程 attachTimer vs finish/cancel 竞态
        for i in 0..<80 {
            let probeCancelSem = DispatchSemaphore(value: 0)
            let probeReport = await withCheckedContinuation { (cont: CheckedContinuation<ProbeReport, Never>) in
                let box = LockedProbeRunBox()
                let once = LockedOnceProbeContinuation(cont)
                _ = box.register(once)

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + .milliseconds(5))
                timer.setEventHandler {
                    once.finish(
                        with: ProbeReport(provider: ProviderCatalog.opencode, failure: "timeout"),
                        cancelWork: true
                    )
                }
                timer.setCancelHandler {
                    probeCancelSem.signal()
                }

                let startGate = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    startGate.signal()
                    if i % 2 == 0 {
                        once.finish(
                            with: ProbeReport(provider: ProviderCatalog.opencode, failure: nil, isMissingProbe: true),
                            cancelWork: false
                        )
                    } else {
                        box.cancel(provider: ProviderCatalog.opencode, started: Date())
                    }
                }
                _ = startGate.wait(timeout: .now() + 1.0)
                once.attachTimer(timer)
            }
            XCTAssertEqual(probeCancelSem.wait(timeout: .now() + 2.0), .success)
            XCTAssertEqual(probeReport.provider.id, ProviderCatalog.opencode.id)

            let kcCancelSem = DispatchSemaphore(value: 0)
            let kcResult = await withCheckedContinuation { (cont: CheckedContinuation<AgyKeychainReadResult, Never>) in
                let box = LockedKeychainCancelBox()
                let once = LockedKeychainContinuation(cont)
                _ = box.register(once)

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + .milliseconds(5))
                timer.setEventHandler {
                    once.finish(with: .timeout)
                }
                timer.setCancelHandler {
                    kcCancelSem.signal()
                }

                let startGate = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    startGate.signal()
                    if i % 2 == 0 {
                        once.finish(with: .missing)
                    } else {
                        box.cancel()
                    }
                }
                _ = startGate.wait(timeout: .now() + 1.0)
                once.attachTimer(timer)
            }
            XCTAssertEqual(kcCancelSem.wait(timeout: .now() + 2.0), .success)
            XCTAssertTrue(kcResult == .missing || kcResult == .timeout)
        }

        // 3. 高频并发：AgyNativeProbe.readKeychainBoundedAsync 极速完成与取消竞态
        let fastKC = ImmediateAgyKeychainReader(result: .missing)
        let probe = AgyNativeProbe(
            transport: MockNativeHTTPTransport(),
            keychain: fastKC,
            keychainTimeoutSeconds: 0.5
        )
        for i in 0..<40 {
            let task = Task {
                await probe.readKeychainBoundedAsync(
                    service: AgyNativeProbe.keychainService,
                    account: AgyNativeProbe.keychainAccount
                )
            }
            if i % 2 == 0 {
                task.cancel()
            }
            let result = await task.value
            XCTAssertTrue(result == .missing || result == .timeout)
        }
    }
}
