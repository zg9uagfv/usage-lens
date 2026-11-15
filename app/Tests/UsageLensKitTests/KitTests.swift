import XCTest
@testable import UsageLensKit

final class ProbeContractTests: XCTestCase {
    private let fullSample = """
    {
      "schema": "usage-lens/probe@1",
      "provider": "codex",
      "account": { "label": "user@example.com", "plan": "plus" },
      "generated_at": "2026-11-15T10:20:00Z",
      "windows": [
        {
          "id": "5h",
          "label": "5 小时",
          "used_percent": 33.0,
          "window_seconds": 18000,
          "resets_at": "2026-11-15T13:00:00Z",
          "basis": "server"
        }
      ],
      "balance": null,
      "spend": null,
      "coverage": null,
      "warnings": [],
      "error": null
    }
    """

    func testDecodesFullSample() throws {
        let envelope = try XCTUnwrap(ProbeJSON.decode(fullSample))
        XCTAssertEqual(envelope.schema, probeSchema)
        XCTAssertNil(envelope.schemaMismatch)
        XCTAssertEqual(envelope.account?.label, "user@example.com")
        XCTAssertEqual(envelope.account?.plan, "plus")
        XCTAssertEqual(envelope.windows.count, 1)
        let window = try XCTUnwrap(envelope.windows.first)
        XCTAssertEqual(window.id, "5h")
        XCTAssertEqual(window.label, "5 小时")
        XCTAssertEqual(window.usedPercent, 33.0)
        XCTAssertEqual(window.basis, "server")
        XCTAssertNotNil(window.resetsAt)
        let expectedReset = try XCTUnwrap(ProbeDate.parse("2026-11-15T13:00:00Z"))
        XCTAssertEqual(window.resetsAt, expectedReset)
    }

    func testNullUsedPercentStaysNilNotZero() throws {
        let json = """
        {"schema":"usage-lens/probe@1","provider":"deepseek","windows":[
          {"id":"5h","label":"5 小时","used_percent":null,"basis":"server"}]}
        """
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertNil(envelope.windows.first?.usedPercent)
        XCTAssertEqual(UsageFormat.usedText(envelope.windows.first?.usedPercent), "未知")
    }

    func testMissingWindowsBecomesEmptyArray() throws {
        let json = #"{"schema":"usage-lens/probe@1","provider":"deepseek"}"#
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertTrue(envelope.windows.isEmpty)
        XCTAssertEqual(envelope.warnings, [])
    }

    func testStringlyTypedNumbersAreAccepted() throws {
        let json = """
        {"schema":"usage-lens/probe@1","provider":"codex","windows":[
          {"id":"5h","used_percent":"41.5","window_seconds":"18000","resets_at":1763200000}]}
        """
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        let window = try XCTUnwrap(envelope.windows.first)
        XCTAssertEqual(window.usedPercent, 41.5)
        XCTAssertEqual(window.windowSeconds, 18000)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_763_200_000))
    }

    func testSchemaMismatchIsReported() throws {
        let json = #"{"schema":"usage-lens/probe@0","provider":"codex","windows":[]}"#
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertNotNil(envelope.schemaMismatch)
    }

    func testGarbageIsNotParsed() {
        XCTAssertNil(ProbeJSON.decode(""))
        XCTAssertNil(ProbeJSON.decode("Traceback (most recent call last):\n  boom"))
    }

    func testWarningToleratesSingleString() throws {
        let json = #"{"schema":"usage-lens/probe@1","warnings":"余额需要 API key"}"#
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertEqual(envelope.warnings, ["余额需要 API key"])
    }
}

final class FormattingTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(UsageFormat.percent(33), "33%")
        XCTAssertEqual(UsageFormat.percent(41.4), "41%")
        XCTAssertEqual(UsageFormat.percent(41.46), "41%")
        XCTAssertEqual(UsageFormat.percent(0.4), "0.4%")
        XCTAssertEqual(UsageFormat.percent(120), "100%")
        XCTAssertEqual(UsageFormat.percent(nil), "未知")
        XCTAssertEqual(UsageFormat.usedText(7), "已用 7%")
        XCTAssertEqual(UsageFormat.usedText(nil), "未知")
    }

    func testFraction() throws {
        XCTAssertEqual(try XCTUnwrap(UsageFormat.fraction(33)), 0.33, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(UsageFormat.fraction(0)), 0)
        XCTAssertNil(UsageFormat.fraction(nil))
    }

    func testResetCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: 30), now: now), "30 分后重置")
        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: 90), now: now), "1 小时 30 分后重置")
        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: 120), now: now), "2 小时后重置")
        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: 96 * 60), now: now), "4 天 0 小时后重置")
        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: 26 * 60 + 30), now: now), "1 天 2 小时后重置")
        XCTAssertEqual(UsageFormat.resetCountdown(until: at(minutes: -1), now: now), "窗口已过期")
        XCTAssertNil(UsageFormat.resetCountdown(until: nil, now: now))
    }

    func testIsExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UsageFormat.isExpired(resetAt: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(UsageFormat.isExpired(resetAt: now.addingTimeInterval(60), now: now))
        XCTAssertFalse(UsageFormat.isExpired(resetAt: nil, now: now))
    }

    func testUpdatedText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UsageFormat.updatedText(at: now.addingTimeInterval(-10), now: now), "刚刚更新")
        XCTAssertEqual(UsageFormat.updatedText(at: now.addingTimeInterval(-180), now: now), "3 分钟前更新")
        XCTAssertEqual(UsageFormat.updatedText(at: now.addingTimeInterval(-7200), now: now), "2 小时前更新")
        XCTAssertEqual(UsageFormat.updatedText(at: nil, now: now), "尚未更新")
    }

    func testSourceAndBasisLabels() {
        XCTAssertEqual(UsageFormat.sourceLabel("official"), "官方")
        XCTAssertEqual(UsageFormat.sourceLabel("estimate"), "估算")
        XCTAssertNil(UsageFormat.sourceLabel(nil))
        XCTAssertEqual(UsageFormat.basisLabel("server"), "服务端")
        XCTAssertEqual(UsageFormat.basisLabel("local"), "本地推导")
        XCTAssertNil(UsageFormat.basisLabel(""))
        XCTAssertEqual(UsageFormat.planLabel("plus"), "Plus")
        XCTAssertEqual(UsageFormat.planLabel("max_plan"), "Max Plan")
        XCTAssertNil(UsageFormat.planLabel(nil))
    }

    func testMoney() {
        XCTAssertEqual(UsageFormat.money(12.3, currency: "CNY"), "¥12.30")
        XCTAssertEqual(UsageFormat.money(0.42, currency: "USD"), "$0.42")
        XCTAssertNil(UsageFormat.money(nil, currency: "CNY"))
    }
}

final class SecretRedactorTests: XCTestCase {
    func testRedactsOpenAIKey() {
        let output = SecretRedactor.redact("调用失败 sk-abc123DEF456ghi789，请重试")
        XCTAssertTrue(output.contains("***"))
        XCTAssertFalse(output.contains("sk-abc123"))
        XCTAssertTrue(output.contains("请重试"))
    }

    func testRedactsBearerToken() {
        let output = SecretRedactor.redact("header Authorization: Bearer abc.def-123 sent")
        XCTAssertTrue(output.contains("***"))
        XCTAssertFalse(output.contains("abc.def-123"))
        XCTAssertTrue(output.contains("header"))
    }

    func testRedactsKeyValueInURL() {
        let output = SecretRedactor.redact("GET https://api.example.com/user/balance?key=supersecret123 failed")
        XCTAssertTrue(output.contains("***"))
        XCTAssertFalse(output.contains("supersecret123"))
        XCTAssertTrue(output.contains("https://api.example.com"))
    }

    func testRedactsLongRandomRun() {
        let run = String(repeating: "A1b2C3d4", count: 4) // 32 字符
        let output = SecretRedactor.redact("payload \(run) end")
        XCTAssertTrue(output.contains("***"))
        XCTAssertFalse(output.contains(run))
        XCTAssertTrue(output.contains("payload"))
    }

    func testKeepsNormalChineseText() {
        XCTAssertEqual(SecretRedactor.redact("探针超时（>6s）"), "探针超时（>6s）")
        XCTAssertEqual(SecretRedactor.redact("日志目录不存在，请检查 ~/.codex"), "日志目录不存在，请检查 ~/.codex")
        XCTAssertEqual(SecretRedactor.redact("schema 不符：usage-lens/probe@0"), "schema 不符：usage-lens/probe@0")
    }

    func testStderrReachingUIIsRedacted() {
        let runner = ProbeRunner(root: URL(fileURLWithPath: "/tmp"))
        let report = runner.decode(
            provider: ProviderCatalog.codex,
            stdout: "",
            stderr: "boom sk-abcdefgh12345 Bearer token.value\nline two",
            status: 1,
            finishedAt: Date(),
            duration: 0.01
        )
        let failure = report.failure ?? ""
        XCTAssertTrue(failure.contains("***"))
        XCTAssertFalse(failure.contains("sk-abcdefgh12345"))
        XCTAssertFalse(failure.contains("token.value"))
        XCTAssertTrue(failure.contains("boom"))
    }

    func testWarningsAreRedactedToo() {
        let report = ProbeReport(
            provider: ProviderCatalog.deepseek,
            envelope: ProbeEnvelope(provider: "deepseek", warnings: ["余额查询失败 key=abc123secret"])
        )
        XCTAssertEqual(report.warnings, ["余额查询失败 ***"])
    }
}

final class StateReducerTests: XCTestCase {
    private func envelope(percent: Double?) -> ProbeEnvelope {
        ProbeEnvelope(
            provider: "codex",
            windows: [ProbeWindow(id: "5h", label: "5 小时", usedPercent: percent, basis: "server")]
        )
    }

    func testFailureKeepsLastValueAndMarksStale() {
        var state = ProviderState(provider: ProviderCatalog.codex)
        let success = ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: envelope(percent: 33),
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        state = ProviderReducer.apply(success, to: state)
        XCTAssertEqual(state.status, .ok)
        XCTAssertEqual(state.lastDataAt, Date(timeIntervalSince1970: 100))

        let failure = ProbeReport(provider: ProviderCatalog.codex, failure: "探针超时", finishedAt: Date(timeIntervalSince1970: 200))
        state = ProviderReducer.apply(failure, to: state)
        XCTAssertEqual(state.status, .stale)
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.windows.first?.usedPercent, 33)
        XCTAssertEqual(state.lastDataAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(state.lastAttemptAt, Date(timeIntervalSince1970: 200))
    }

    func testMissingProbeClearsData() {
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.deepseek, envelope: envelope(percent: 10)),
            to: state
        )
        XCTAssertEqual(state.windows.count, 1)

        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.deepseek, failure: "未安装探针", isMissingProbe: true),
            to: state
        )
        XCTAssertEqual(state.status, .missing)
        XCTAssertNil(state.envelope)
        XCTAssertNil(state.lastDataAt)
    }

    func testSpendValueFiltersContradictoryWarnings() {
        let envelope = ProbeEnvelope(
            provider: "deepseek",
            spend: ProbeSpend(today: 0.42, window: 3.18, currency: "CNY", source: "estimate"),
            warnings: [
                "余额需要 API key",
                "DeepSeek 会话日志里没有 token 用量记录，无法估算花费",
                "本地花费为 0，仅供参考",
            ]
        )
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.deepseek, envelope: envelope), to: state)
        XCTAssertEqual(state.warnings.count, 3, "原始 warnings 保留")
        XCTAssertEqual(state.visibleWarnings, ["余额需要 API key"], "有 spend 值时过滤矛盾的 warning")
    }

    func testWarningsNotFilteredWithoutSpend() {
        let envelope = ProbeEnvelope(
            provider: "deepseek",
            warnings: ["余额需要 API key", "没有 token 用量记录，无法估算花费"]
        )
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.deepseek, envelope: envelope), to: state)
        XCTAssertEqual(state.visibleWarnings.count, 2, "没有 spend 时不该吞掉任何 warning")
    }

    func testWarningsOnlyIsWarningNotOk() {
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        let envelope = ProbeEnvelope(
            provider: "deepseek",
            warnings: ["余额需要 API key"]
        )
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.deepseek, envelope: envelope), to: state)
        XCTAssertEqual(state.status, .warning)
    }

    func testFailureWithoutDataIsFailed() {
        var state = ProviderState(provider: ProviderCatalog.codex)
        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.codex, failure: "探针超时（>6s）"),
            to: state
        )
        XCTAssertEqual(state.status, .failed)
        XCTAssertNil(state.envelope)
    }

    func testNoWindowsNoMetricsIsEmptyNotZero() {
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.deepseek, envelope: ProbeEnvelope(provider: "deepseek")),
            to: state
        )
        XCTAssertEqual(state.status, .empty)
        XCTAssertTrue(state.windows.isEmpty)
    }

    func testWarningSteersStatus() {
        var state = ProviderState(provider: ProviderCatalog.deepseek)
        let envelope = ProbeEnvelope(
            provider: "deepseek",
            balance: ProbeBalance(amount: 12, currency: "CNY", source: "official"),
            warnings: ["余额需要 API key"]
        )
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.deepseek, envelope: envelope), to: state)
        XCTAssertEqual(state.status, .warning)
    }

    func testMostTensePicksHighestPercent() {
        var codex = ProviderState(provider: ProviderCatalog.codex)
        codex = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.codex, envelope: ProbeEnvelope(
                provider: "codex",
                windows: [
                    ProbeWindow(id: "5h", label: "5 小时", usedPercent: 33),
                    ProbeWindow(id: "7d", label: "7 天", usedPercent: 61),
                ]
            )),
            to: codex
        )
        var deepseek = ProviderState(provider: ProviderCatalog.deepseek)
        deepseek = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.deepseek, envelope: ProbeEnvelope(
                provider: "deepseek",
                windows: [ProbeWindow(id: "5h", usedPercent: nil)]
            )),
            to: deepseek
        )

        let tension = Tension.mostTense(in: [codex, deepseek])
        XCTAssertEqual(tension?.provider, ProviderCatalog.codex)
        XCTAssertEqual(tension?.window.id, "7d")
        XCTAssertEqual(tension?.compactLabel, "Codex 7d 61%")
    }

    func testMostTenseNilWhenNoPercentAvailable() {
        var state = ProviderState(provider: ProviderCatalog.codex)
        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.codex, envelope: ProbeEnvelope(
                provider: "codex",
                windows: [ProbeWindow(id: "5h", usedPercent: nil)]
            )),
            to: state
        )
        XCTAssertNil(Tension.mostTense(in: [state]))
    }
}

final class ProbeRunnerDecodeTests: XCTestCase {
    func testNonZeroExitWithJSONKeepsEnvelope() {
        let runner = ProbeRunner(root: URL(fileURLWithPath: "/tmp"))
        let json = #"{"schema":"usage-lens/probe@1","provider":"codex","error":"日志目录不可读","warnings":["w1"]}"#
        let report = runner.decode(
            provider: ProviderCatalog.codex,
            stdout: json,
            stderr: "",
            status: 2,
            finishedAt: Date(),
            duration: 0.01
        )
        XCTAssertEqual(report.failure, "日志目录不可读")
        XCTAssertNotNil(report.envelope)
        XCTAssertEqual(report.warnings, ["w1"])
    }

    func testNonZeroExitWithCleanJSONIsNotAFailure() {
        let runner = ProbeRunner(root: URL(fileURLWithPath: "/tmp"))
        let json = #"{"schema":"usage-lens/probe@1","provider":"codex","windows":[{"id":"5h","used_percent":21,"basis":"server"}]}"#
        let report = runner.decode(
            provider: ProviderCatalog.codex,
            stdout: json,
            stderr: "",
            status: 3,
            finishedAt: Date(),
            duration: 0.01
        )
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.envelope?.windows.first?.usedPercent, 21)
    }

    func testBrokenStdoutUsesStderrLine() {
        let runner = ProbeRunner(root: URL(fileURLWithPath: "/tmp"))
        let report = runner.decode(
            provider: ProviderCatalog.codex,
            stdout: "",
            stderr: "No such file: ~/ProviderCatalog.codex\nline two",
            status: 1,
            finishedAt: Date(),
            duration: 0.01
        )
        XCTAssertNil(report.envelope)
        XCTAssertEqual(report.failure, "探针没有输出内容（No such file: ~/ProviderCatalog.codex）")
    }
}
