import Foundation
import XCTest
@testable import UsageLensKit

private func isoUTC(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
}

private func writeText(_ text: String, to url: URL, mtime: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let mtime {
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
}

private func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-lens-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - CodexProbeTests

final class CodexNativeProbeTests: XCTestCase {
    private var root: URL!
    private var sessions: URL!

    override func setUpWithError() throws {
        root = try makeTempDir("codex")
        sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tokenCountLine(
        primary: Any,
        secondary: Any,
        resetsPrimary: TimeInterval,
        resetsSecondary: TimeInterval,
        plan: String = "plus",
        timestamp: Date
    ) throws -> String {
        let obj: [String: Any] = [
            "timestamp": isoUTC(timestamp),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "primary": [
                        "used_percent": primary,
                        "window_minutes": 300,
                        "resets_at": resetsPrimary,
                    ],
                    "secondary": [
                        "used_percent": secondary,
                        "window_minutes": 10080,
                        "resets_at": resetsSecondary,
                    ],
                    "plan_type": plan,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    func testNormalFrameAndTodayTokens() throws {
        let now = Date()
        let frameTime = now.addingTimeInterval(-60)
        let resets1 = now.timeIntervalSince1970 + 3600
        let resets2 = now.timeIntervalSince1970 + 86_400

        let lines = [
            try tokenCountLine(primary: 35.0, secondary: 14.0, resetsPrimary: resets1, resetsSecondary: resets2, timestamp: frameTime.addingTimeInterval(-30)),
            #"{"timestamp":"\#(isoUTC(frameTime))","type":"token_usage_record","payload":{"usage":{"total_tokens":120}}}"#,
            #"{"timestamp":"\#(isoUTC(frameTime))","type":"event_msg","payload":{"type":"token_usage_record","usage":{"total_tokens":80}}}"#,
            #"{"timestamp":"\#(isoUTC(now.addingTimeInterval(-86_400 * 2)))","type":"token_usage_record","payload":{"usage":{"total_tokens":999}}}"#,
            try tokenCountLine(primary: 21.0, secondary: 18.0, resetsPrimary: resets1, resetsSecondary: resets2, timestamp: frameTime),
        ]
        try writeText(
            lines.joined(separator: "\n") + "\n",
            to: sessions.appendingPathComponent("2026/11/20/rollout-new.jsonl"),
            mtime: frameTime
        )

        let report = CodexProbe(sessionsDirectory: sessions, now: { now }).run()
        XCTAssertNil(report.failure)
        let env = try XCTUnwrap(report.envelope)
        XCTAssertEqual(env.provider, "codex")
        XCTAssertEqual(env.account?.plan, "plus")
        XCTAssertNil(env.account?.label)
        XCTAssertEqual(env.stale, false)
        XCTAssertEqual(env.windows.count, 2)
        XCTAssertEqual(env.windows[0].id, "5h")
        XCTAssertEqual(env.windows[0].usedPercent, 21.0)
        XCTAssertEqual(env.windows[0].expired, false)
        XCTAssertEqual(env.windows[1].id, "7d")
        XCTAssertEqual(env.windows[1].usedPercent, 18.0)
        XCTAssertEqual(env.usage?.todayTokens, 200)
        XCTAssertEqual(env.usage?.source, "local")
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testSameMtimeUsesContentTimestampInBothOrders() throws {
        let now = Date()
        let base = now.addingTimeInterval(-3600)
        let older = base.addingTimeInterval(-600)
        let resets1 = now.timeIntervalSince1970 + 3600
        let resets2 = now.timeIntervalSince1970 + 86_400

        let scenarios: [[(String, Double, Date)]] = [
            [
                ("2026/11/20/rollout-z-old.jsonl", 11.0, older),
                ("2026/11/20/rollout-a-new.jsonl", 22.0, base),
            ],
            [
                ("2026/11/20/rollout-a-old.jsonl", 11.0, older),
                ("2026/11/20/rollout-z-new.jsonl", 22.0, base),
            ],
        ]
        for files in scenarios {
            try? FileManager.default.removeItem(at: sessions)
            for (rel, pct, ts) in files {
                let line = try tokenCountLine(primary: pct, secondary: 5.0, resetsPrimary: resets1, resetsSecondary: resets2, timestamp: ts)
                try writeText(line + "\n", to: sessions.appendingPathComponent(rel), mtime: base)
            }
            let report = CodexProbe(sessionsDirectory: sessions, now: { now }).run()
            XCTAssertEqual(report.envelope?.windows.first?.usedPercent, 22.0)
        }
    }

    func testExpiredAndStaleWindowsEmitWarnings() throws {
        let now = Date()
        let old = now.addingTimeInterval(-4 * 86_400)
        let line = try tokenCountLine(
            primary: 21.0,
            secondary: 18.0,
            resetsPrimary: old.timeIntervalSince1970 + 3600,
            resetsSecondary: old.timeIntervalSince1970 + 86_400,
            timestamp: old
        )
        try writeText(line + "\n", to: sessions.appendingPathComponent("2026/11/10/rollout-old.jsonl"), mtime: old)

        let report = CodexProbe(sessionsDirectory: sessions, now: { now }).run()
        let env = try XCTUnwrap(report.envelope)
        XCTAssertEqual(env.stale, true)
        XCTAssertEqual(env.windows[0].expired, true)
        XCTAssertEqual(env.windows[1].expired, true)
        XCTAssertTrue(report.warnings.contains { $0.contains("重置") })
        XCTAssertTrue(report.warnings.contains { $0.contains("可能不是当前状态") })
    }

    func testOutOfRangePercentBecomesNilWithWarning() throws {
        let now = Date()
        let resets = now.timeIntervalSince1970 + 3600
        let line = try tokenCountLine(primary: 150.0, secondary: -5.0, resetsPrimary: resets, resetsSecondary: resets + 86_400, timestamp: now)
        try writeText(line + "\n", to: sessions.appendingPathComponent("2026/11/20/rollout-range.jsonl"), mtime: now)

        let report = CodexProbe(sessionsDirectory: sessions, now: { now }).run()
        XCTAssertNil(report.envelope?.windows[0].usedPercent)
        XCTAssertNil(report.envelope?.windows[1].usedPercent)
        XCTAssertTrue(report.warnings.contains { $0.contains("数值异常") })
    }

    func testMissingOrCorruptLogsDegradeGracefully() throws {
        try FileManager.default.removeItem(at: sessions)
        let missing = CodexProbe(sessionsDirectory: sessions).run()
        XCTAssertNil(missing.failure)
        XCTAssertTrue(missing.envelope?.windows.isEmpty ?? false)
        XCTAssertTrue(missing.warnings.contains { $0.contains("~/.codex/sessions") })

        try writeText("{broken json\nnot json\n", to: sessions.appendingPathComponent("rollout-bad.jsonl"))
        let corrupt = CodexProbe(sessionsDirectory: sessions).run()
        XCTAssertNil(corrupt.failure)
        XCTAssertTrue(corrupt.envelope?.windows.isEmpty ?? false)
        XCTAssertTrue(corrupt.warnings.contains { $0.contains("无法解析") })
    }
}

// MARK: - GeminiProbeTests

final class GeminiNativeProbeTests: XCTestCase {
    private var root: URL!
    private var geminiHome: URL!

    override func setUpWithError() throws {
        root = try makeTempDir("gemini")
        geminiHome = root.appendingPathComponent(".gemini", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTranscript(
        subdir: String = "antigravity-cli",
        convID: String,
        filename: String = "transcript.jsonl",
        lines: [String]
    ) throws {
        let url = geminiHome
            .appendingPathComponent(subdir, isDirectory: true)
            .appendingPathComponent("brain/\(convID)/.system_generated/logs/\(filename)")
        try writeText(lines.joined(separator: "\n") + "\n", to: url)
    }

    private func plannerLine(
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        model: String? = "gemini-2.5-pro",
        date: Date
    ) throws -> String {
        var obj: [String: Any] = [
            "type": "PLANNER_RESPONSE",
            "created_at": isoUTC(date),
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_tokens": cacheRead,
        ]
        if let model { obj["model"] = model }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    func testMissingGeminiDirReturnsEmptyWithWarning() {
        let report = GeminiProbe(geminiHome: geminiHome).run()
        XCTAssertNil(report.failure)
        XCTAssertTrue(report.envelope?.windows.isEmpty ?? false)
        XCTAssertNil(report.envelope?.usage)
        XCTAssertNil(report.envelope?.spend)
        XCTAssertTrue(report.warnings.contains { $0.contains("~/.gemini") })
    }

    func testAntigravityTranscriptAggregatesAndIgnoresFullAndBackup() throws {
        let now = Date()
        try writeTranscript(convID: "conv-1", lines: [
            #"{"type":"USER_INPUT","created_at":"\#(isoUTC(now))","content":"hi"}"#,
            try plannerLine(input: 1_000_000, output: 100_000, cacheRead: 2_000_000, model: "gemini-2.5-pro", date: now),
        ])
        // transcript_full.jsonl 不得重复计入
        try writeTranscript(convID: "conv-1", filename: "transcript_full.jsonl", lines: [
            try plannerLine(input: 9_000_000, output: 9_000_000, model: "gemini-2.5-pro", date: now),
        ])
        // antigravity-backup 不得重复计入
        try writeTranscript(subdir: "antigravity-backup", convID: "conv-backup", lines: [
            try plannerLine(input: 5_000_000, output: 5_000_000, model: "gemini-2.5-pro", date: now),
        ])

        let report = GeminiProbe(geminiHome: geminiHome, now: { now }).run()
        let env = try XCTUnwrap(report.envelope)
        XCTAssertTrue(env.windows.isEmpty)
        XCTAssertEqual(env.usage?.todayTokens, 1_100_000)
        XCTAssertEqual(env.usage?.source, "local")
        // 1M * 1.25 + 0.1M * 10.0 + 2M * 0.125 = 2.50 USD
        XCTAssertEqual(try XCTUnwrap(env.spend?.today), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.window), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.total), 2.5, accuracy: 0.0001)
        XCTAssertEqual(env.spend?.currency, "USD")
        XCTAssertTrue(report.warnings.contains { $0.contains("cache tokens 2000000") })
    }

    func testGeminiCLISessionAndWindowExclusion() throws {
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 86_400)

        try writeTranscript(convID: "old-conv", lines: [
            try plannerLine(input: 1_000_000, output: 0, model: nil, date: eightDaysAgo),
        ])

        let cliPayload: [String: Any] = [
            "sessionId": "s1",
            "lastUpdated": isoUTC(now),
            "messages": [
                [
                    "type": "gemini",
                    "timestamp": isoUTC(now),
                    "model": "gemini-2.5-flash",
                    "tokens": [
                        "input": 1_500_000,
                        "cached": 500_000,
                        "output": 80_000,
                        "thoughts": 20_000,
                        "tool": 0,
                    ],
                ],
            ],
        ]
        let cliData = try JSONSerialization.data(withJSONObject: cliPayload)
        try writeText(
            String(decoding: cliData, as: UTF8.self),
            to: geminiHome.appendingPathComponent("tmp/proj/chats/session-2026.json")
        )

        let report = GeminiProbe(geminiHome: geminiHome, now: { now }).run()
        let env = try XCTUnwrap(report.envelope)
        XCTAssertEqual(env.usage?.todayTokens, 1_100_000)
        // flash today = 1M*0.30 + 0.1M*2.50 + 0.5M*0.03 = 0.565
        // old (8d ago, fallback pro) = 1.25 -> excluded from window, included in total
        XCTAssertEqual(try XCTUnwrap(env.spend?.today), 0.565, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.window), 0.565, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.total), 1.815, accuracy: 0.0001)
        XCTAssertTrue(report.warnings.contains { $0.contains("兜底估算") })
    }

    func testCorruptLinesAndFilesDoNotCrash() throws {
        let now = Date()
        try writeTranscript(convID: "corrupt", lines: [
            "{broken json",
            try plannerLine(input: 500, output: 100, model: "gemini-2.5-flash-lite", date: now),
        ])
        try writeText("{bad", to: geminiHome.appendingPathComponent("tmp/p/chats/session-bad.json"))

        let report = GeminiProbe(geminiHome: geminiHome, now: { now }).run()
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.envelope?.usage?.todayTokens, 600)
        XCTAssertTrue(report.warnings.contains { $0.contains("无法解析") })
    }
}

// MARK: - DeepSeekProbeTests

final class DeepSeekNativeProbeTests: XCTestCase {
    private var root: URL!
    private var projcache: URL!
    private var sessions: URL!

    override func setUpWithError() throws {
        root = try makeTempDir("deepseek")
        projcache = root.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
        sessions = root.appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeProjcache(id: String, totals: [String: Any], createdAtMs: Int64) throws {
        let payload: [String: Any] = [
            "version": 7,
            "record": [
                "identity": ["createdAt": createdAtMs],
                "rows": [
                    "tokenUsage": [
                        "val": ["totals": totals],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try writeText(String(decoding: data, as: UTF8.self), to: projcache.appendingPathComponent("\(id).json"))
    }

    func testNoKeyMakesZeroNetworkCalls() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let probe = DeepSeekProbe(
            projcacheDirectory: projcache,
            sessionsDirectory: sessions,
            balanceFetcher: { _ in
                counter.calls += 1
                return (nil, ["should not be called"])
            }
        )
        let report = await probe.run(apiKey: nil)
        XCTAssertEqual(counter.calls, 0, "无 key 时绝不发网络请求")
        XCTAssertNil(report.envelope?.balance)
        XCTAssertTrue(report.envelope?.windows.isEmpty ?? false)
        XCTAssertTrue(report.warnings.contains { $0.contains("API key") })
    }

    func testProjcacheSpendAndWindowExclusion() async throws {
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 86_400)
        try writeProjcache(
            id: "old",
            totals: ["uncachedInputTokens": 1_000_000, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0],
            createdAtMs: Int64(eightDaysAgo.timeIntervalSince1970 * 1000)
        )
        try writeProjcache(
            id: "today",
            totals: ["uncachedInputTokens": 1_000_000, "outputTokens": 100_000, "cacheReadTokens": 500_000, "cacheWriteTokens": 0],
            createdAtMs: Int64(now.timeIntervalSince1970 * 1000)
        )

        let probe = DeepSeekProbe(
            projcacheDirectory: projcache,
            sessionsDirectory: sessions,
            balanceFetcher: { _ in
                (ProbeBalance(amount: 88.5, currency: "CNY", source: "official"), [])
            },
            now: { now }
        )
        let report = await probe.run(apiKey: "sk-test-key-12345678")
        let env = try XCTUnwrap(report.envelope)
        XCTAssertEqual(env.balance, ProbeBalance(amount: 88.5, currency: "CNY", source: "official"))
        // today: 1M*2 + 0.5M*0.2 + 0.1M*3 = 2.4 CNY
        // old (8d ago): 1M*2 = 2.0 CNY -> total 4.4, window 2.4
        XCTAssertEqual(try XCTUnwrap(env.spend?.today), 2.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.window), 2.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(env.spend?.total), 4.4, accuracy: 0.0001)
        XCTAssertEqual(env.spend?.currency, "CNY")
        XCTAssertTrue(env.coverage?.note?.contains("window=近 7 天") ?? false)
    }

    func testOfficialURLValidation() {
        XCTAssertTrue(DeepSeekProbe.isOfficialURL("https://api.deepseek.com/user/balance"))
        XCTAssertTrue(DeepSeekProbe.isOfficialURL("https://api.deepseek.com/user/balance?x=1"))
        XCTAssertFalse(DeepSeekProbe.isOfficialURL("http://api.deepseek.com/user/balance"))
        XCTAssertFalse(DeepSeekProbe.isOfficialURL("https://api.deepseek.com.evil.com/x"))
        XCTAssertFalse(DeepSeekProbe.isOfficialURL("https://evil.com/api.deepseek.com"))
        XCTAssertFalse(DeepSeekProbe.isOfficialURL("https://api.deepseek.com:8443/x"))
        XCTAssertFalse(DeepSeekProbe.isOfficialURL("https://api.deepseek.com@evil.com/x"))
    }

    func testBalanceBodyParsingAndErrorMessages() {
        let body = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"10.00"},{"currency":"CNY","total_balance":"70.50"}]}"#.utf8)
        let (balance, warnings) = DeepSeekProbe.parseBalanceBody(body)
        XCTAssertEqual(balance, ProbeBalance(amount: 70.5, currency: "CNY", source: "official"))
        XCTAssertTrue(warnings.isEmpty)

        XCTAssertTrue(DeepSeekProbe.httpErrorMessage(302).contains("拒绝跟随"))
        XCTAssertTrue(DeepSeekProbe.httpErrorMessage(401).contains("API key 无效"))
        XCTAssertTrue(DeepSeekProbe.httpErrorMessage(429).contains("限流"))
        XCTAssertTrue(DeepSeekProbe.httpErrorMessage(503).contains("暂时不可用"))
    }

    func testRedirectDelegateRejectsRedirection() {
        let delegate = RejectRedirectDelegate()
        let exp = expectation(description: "redirect rejected")
        let dummyURL = URL(string: "https://api.deepseek.com/user/balance")!
        let redirect = HTTPURLResponse(url: dummyURL, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/steal"])!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: dummyURL)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://evil.example/steal")!)) { nextRequest in
            XCTAssertNil(nextRequest, "重定向必须返回 nil 拒绝跟随")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        session.invalidateAndCancel()
    }

    func testUnsupportedProviderReturnsMissingProbe() async {
        let runner = ProbeRunner()
        let report = await runner.report(for: ProviderCatalog.opencode)
        XCTAssertTrue(report.isMissingProbe)
        XCTAssertNil(report.envelope)
    }
}
