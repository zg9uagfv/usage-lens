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
      "usage": { "today_tokens": 123456, "source": "local" },
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
        XCTAssertEqual(envelope.usage?.todayTokens, 123_456)
        XCTAssertEqual(envelope.usage?.source, "local")
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

final class ContractV2Tests: XCTestCase {
    func testDecodesObservedAtStaleAndExpired() throws {
        let json = """
        {"schema":"usage-lens/probe@1","provider":"codex",
         "generated_at":"2026-11-15T10:20:00Z",
         "observed_at":"2026-11-11T01:25:26Z",
         "stale":true,
         "windows":[{"id":"5h","used_percent":21,"resets_at":"2026-11-11T05:28:56Z","expired":true}]}
        """
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertEqual(envelope.observedAt, ProbeDate.parse("2026-11-11T01:25:26Z"))
        XCTAssertEqual(envelope.effectiveObservedAt, envelope.observedAt)
        XCTAssertTrue(envelope.dataIsStale)
        let window = try XCTUnwrap(envelope.windows.first)
        XCTAssertEqual(window.expired, true)
        XCTAssertTrue(window.isExpired())
    }

    func testStaleDefaultsToFalseAndFallsBackToGeneratedAt() throws {
        let json = #"{"schema":"usage-lens/probe@1","provider":"codex","generated_at":"2026-11-15T10:20:00Z","windows":[]}"#
        let envelope = try XCTUnwrap(ProbeJSON.decode(json))
        XCTAssertFalse(envelope.dataIsStale)
        XCTAssertEqual(envelope.effectiveObservedAt, envelope.generatedAt)
        XCTAssertNil(envelope.windows.first)
    }

    func testSchemaMismatchIsTreatedAsIncompatible() throws {
        let runner = ProbeRunner(root: URL(fileURLWithPath: "/tmp"))
        let json = #"{"schema":"usage-lens/probe@9","provider":"codex","windows":[{"id":"5h","used_percent":88}]}"#
        let report = runner.decode(
            provider: ProviderCatalog.codex,
            stdout: json,
            stderr: "",
            status: 0,
            finishedAt: Date(),
            duration: 0.01
        )
        XCTAssertTrue(report.isIncompatibleSchema)
        XCTAssertNil(report.envelope, "schema 不符时不许保留任何数字")
        XCTAssertTrue(report.failure?.contains("探针输出格式不兼容") ?? false)
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

    func testWindowExpiredFlagAndFallback() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 契约字段优先
        XCTAssertTrue(ProbeWindow(id: "5h", resetsAt: now.addingTimeInterval(3600), expired: true).isExpired(now: now))
        XCTAssertFalse(ProbeWindow(id: "5h", resetsAt: now.addingTimeInterval(-60), expired: false).isExpired(now: now))
        // 缺失时按 resets_at 兜底
        XCTAssertTrue(ProbeWindow(id: "5h", resetsAt: now.addingTimeInterval(-1)).isExpired(now: now))
        XCTAssertFalse(ProbeWindow(id: "5h", resetsAt: now.addingTimeInterval(60)).isExpired(now: now))
        XCTAssertFalse(ProbeWindow(id: "5h").isExpired(now: now))
    }

    func testDataAgeAndExpiredMessages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UsageFormat.dataAgeText(from: now.addingTimeInterval(-30), now: now), "刚刚")
        XCTAssertEqual(UsageFormat.dataAgeText(from: now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
        XCTAssertEqual(UsageFormat.dataAgeText(from: now.addingTimeInterval(-5 * 86_400), now: now), "5 天前")
        XCTAssertNil(UsageFormat.dataAgeText(from: nil, now: now))
        XCTAssertEqual(
            UsageFormat.expiredMessage(observedAt: now.addingTimeInterval(-3 * 86_400), now: now),
            "窗口已过期（数据 3 天前）"
        )
        XCTAssertEqual(UsageFormat.expiredMessage(observedAt: nil, now: now), "窗口已过期")
        XCTAssertEqual(UsageFormat.staleMessage(observedAt: now.addingTimeInterval(-5 * 86_400), now: now), "数据来自 5 天前")
        XCTAssertEqual(UsageFormat.staleMessage(observedAt: nil, now: now), "数据时间未知")
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

    func testTokenCount() {
        XCTAssertEqual(UsageFormat.tokenCount(123_456), "123,456")
        XCTAssertEqual(UsageFormat.tokenCount(nil), "未知")
        XCTAssertEqual(UsageFormat.sourceLabel("local"), "本地统计")
    }

    func testMaskedAccountLabel() {
        XCTAssertEqual(UsageFormat.maskedAccountLabel("user@gmail.com"), "*****@gmail.com")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("a@sub.example.org"), "*****@sub.example.org")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("  alice+tag@gmail.com \n"), "*****@gmail.com")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("org-123456"), "*****")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("Team @ Acme"), "*****")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("@gmail.com"), "*****")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("user@"), "*****")
        XCTAssertEqual(UsageFormat.maskedAccountLabel("@"), "*****")
        XCTAssertNil(UsageFormat.maskedAccountLabel(nil))
        XCTAssertNil(UsageFormat.maskedAccountLabel(""))
        XCTAssertNil(UsageFormat.maskedAccountLabel("   "))
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

final class BlockingStateTests: XCTestCase {
    private func okState(percent: Double, resetsAt: Date? = nil, stale: Bool? = nil) -> ProviderState {
        var state = ProviderState(provider: ProviderCatalog.codex)
        let envelope = ProbeEnvelope(
            provider: "codex",
            observedAt: Date(),
            stale: stale,
            windows: [ProbeWindow(id: "5h", label: "5 小时", usedPercent: percent, resetsAt: resetsAt, basis: "server")]
        )
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.codex, envelope: envelope), to: state)
        return state
    }

    func testIncompatibleSchemaClearsPreviousValues() {
        var state = okState(percent: 77)
        XCTAssertEqual(state.status, .ok)

        state = ProviderReducer.apply(
            ProbeReport(
                provider: ProviderCatalog.codex,
                failure: "探针输出格式不兼容（schema 不符：usage-lens/probe@9）",
                isIncompatibleSchema: true
            ),
            to: state
        )

        XCTAssertEqual(state.status, .incompatible)
        XCTAssertNil(state.envelope)
        XCTAssertNil(state.lastDataAt)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertFalse(state.isStale, "schema 非法时不许出现「上次成功值」")
        XCTAssertNil(Tension.mostTense(in: [state]))
    }

    func testDataStaleIsWarningAndExcludedFromMenuBar() {
        let state = okState(percent: 21, resetsAt: Date().addingTimeInterval(3600), stale: true)
        XCTAssertTrue(state.isDataStale)
        XCTAssertEqual(state.status, .warning)
        XCTAssertNil(Tension.mostTense(in: [state]))
    }

    func testExpiredWindowExcludedFromMenuBar() {
        let state = okState(percent: 21, resetsAt: Date().addingTimeInterval(-60))
        XCTAssertEqual(state.status, .ok)
        XCTAssertNil(Tension.mostTense(in: [state]), "过期窗口不许上菜单栏")
    }

    func testBenignWarningStillShowsInMenuBar() {
        var state = ProviderState(provider: ProviderCatalog.codex)
        let envelope = ProbeEnvelope(
            provider: "codex",
            observedAt: Date(),
            windows: [
                ProbeWindow(
                    id: "5h",
                    label: "5 小时",
                    usedPercent: 21,
                    resetsAt: Date().addingTimeInterval(3600),
                    basis: "server"
                )
            ],
            warnings: ["日志超过 4MB，只读了最后一部分"]
        )
        state = ProviderReducer.apply(ProbeReport(provider: ProviderCatalog.codex, envelope: envelope), to: state)

        XCTAssertEqual(state.status, .warning)
        XCTAssertEqual(Tension.mostTense(in: [state])?.compactLabel, "Codex 5h 21%")
    }

    func testFreshWindowStillShowOnMenuBar() {
        let state = okState(percent: 21, resetsAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(Tension.mostTense(in: [state])?.compactLabel, "Codex 5h 21%")
    }

    func testFailedStaleValuesExcludedFromMenuBar() {
        var state = okState(percent: 77, resetsAt: Date().addingTimeInterval(3600))
        state = ProviderReducer.apply(
            ProbeReport(provider: ProviderCatalog.codex, failure: "探针超时（>6s）"),
            to: state
        )
        XCTAssertEqual(state.status, .stale)
        XCTAssertNil(Tension.mostTense(in: [state]), "失败保留的旧值不许上菜单栏")
    }
}

final class NativeProbeRuntimeTests: XCTestCase {
    func testPinnedHTTPSURLValidation() {
        XCTAssertTrue(NativeProbeSupport.isPinnedHTTPSURLString("https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", expectedHost: "daily-cloudcode-pa.googleapis.com"))
        XCTAssertTrue(NativeProbeSupport.isPinnedHTTPSURLString("https://cloudcode-pa.googleapis.com:443/v1internal:retrieveUserQuota", expectedHost: "cloudcode-pa.googleapis.com"))
        XCTAssertFalse(NativeProbeSupport.isPinnedHTTPSURLString("http://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", expectedHost: "cloudcode-pa.googleapis.com"))
        XCTAssertFalse(NativeProbeSupport.isPinnedHTTPSURLString("https://cloudcode-pa.googleapis.com:8443/x", expectedHost: "cloudcode-pa.googleapis.com"))
        XCTAssertFalse(NativeProbeSupport.isPinnedHTTPSURLString("https://evil@cloudcode-pa.googleapis.com/x", expectedHost: "cloudcode-pa.googleapis.com"))
        XCTAssertFalse(NativeProbeSupport.isPinnedHTTPSURLString("https://cloudcode-pa.googleapis.com.evil.com/x", expectedHost: "cloudcode-pa.googleapis.com"))
    }

    func testCodexNativeProbeLiveFallbackAndTodayTokens() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-codex-native-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = tempHome.appendingPathComponent(".codex/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let futureEpoch = Int(now.addingTimeInterval(7200).timeIntervalSince1970)
        let rollout = """
        {"timestamp":"\(iso)","type":"token_usage_record","payload":{"usage":{"total_tokens":1200}}}
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":32,"window_minutes":300,"resets_at":\(futureEpoch)},"secondary":{"used_percent":14,"window_minutes":10080,"resets_at":\(futureEpoch + 86400)},"plan_type":"plus"}}}
        """
        try rollout.write(to: sessionsDir.appendingPathComponent("rollout-2026-11-22.jsonl"), atomically: true, encoding: .utf8)

        // 1. Live 200 success
        let liveBody = try JSONSerialization.data(withJSONObject: [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 45, "limit_window_seconds": 18_000, "reset_at": futureEpoch],
                "secondary_window": ["used_percent": 20, "limit_window_seconds": 604_800, "reset_at": futureEpoch + 86_400],
            ],
        ])
        let liveTransport = MockNativeHTTPTransport(responses: [
            .success(NativeHTTPResponse(statusCode: 200, finalURL: CodexNativeProbe.usageURL, body: liveBody)),
        ])
        let liveReport = await CodexNativeProbe(transport: liveTransport).run(
            environment: [
                "HOME": tempHome.path,
                "CODEX_ACCESS_TOKEN": "sk-synthetic-codex-token",
                "CODEX_ACCOUNT_EMAIL": "codex@example.com",
            ],
            now: now
        )
        XCTAssertNil(liveReport.failure)
        XCTAssertEqual(liveReport.envelope?.account?.label, "codex@example.com")
        XCTAssertEqual(liveReport.envelope?.account?.plan, "pro")
        XCTAssertEqual(liveReport.envelope?.windows.first(where: { $0.id == "5h" })?.usedPercent, 45)
        XCTAssertEqual(liveReport.envelope?.usage?.todayTokens, 1200)

        // 2. Live 302 redirect rejected -> graceful fallback to local rollout log
        let redirectTransport = MockNativeHTTPTransport(responses: [
            .failure(NativeHTTPError.redirected(statusCode: 302)),
        ])
        let fallbackReport = await CodexNativeProbe(transport: redirectTransport).run(
            environment: [
                "HOME": tempHome.path,
                "CODEX_ACCESS_TOKEN": "sk-synthetic-codex-token",
            ],
            now: now
        )
        XCTAssertNil(fallbackReport.failure)
        XCTAssertEqual(fallbackReport.envelope?.windows.first(where: { $0.id == "5h" })?.usedPercent, 32)
        XCTAssertTrue(fallbackReport.warnings.contains { $0.contains("拒绝跟随") })
    }

    func testDeepSeekNativeProbeNoKeyBalanceAndProjcacheSpend() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("usage-lens-deepseek-native-\(UUID().uuidString)", isDirectory: true)
        let projDir = tempHome.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let createdMs = Int(now.timeIntervalSince1970 * 1000)
        let projData = try JSONSerialization.data(withJSONObject: [
            "record": [
                "identity": ["createdAt": createdMs],
                "rows": [
                    "tokenUsage": [
                        "val": [
                            "totals": [
                                "uncachedInputTokens": 100_000,
                                "cacheReadTokens": 500_000,
                                "outputTokens": 50_000,
                            ],
                        ],
                    ],
                ],
            ],
        ])
        try projData.write(to: projDir.appendingPathComponent("sess-1.json"))

        // 1. No API key -> zero network calls, balance nil, warning + local spend
        let noKeyTransport = MockNativeHTTPTransport()
        let noKeyReport = await DeepSeekNativeProbe(transport: noKeyTransport).run(
            environment: ["HOME": tempHome.path],
            now: now
        )
        XCTAssertTrue(noKeyTransport.calls.isEmpty)
        XCTAssertNil(noKeyReport.envelope?.balance)
        XCTAssertEqual(noKeyReport.envelope?.windows, [])
        XCTAssertTrue(noKeyReport.warnings.contains { $0.contains("余额需要 API key") })
        XCTAssertNotNil(noKeyReport.envelope?.spend?.today)

        // 2. With API key -> official balance 200
        let balBody = try JSONSerialization.data(withJSONObject: [
            "balance_infos": [["currency": "CNY", "total_balance": "12.34"]],
        ])
        let okTransport = MockNativeHTTPTransport(responses: [
            .success(NativeHTTPResponse(statusCode: 200, finalURL: DeepSeekNativeProbe.balanceURL, body: balBody)),
        ])
        let okReport = await DeepSeekNativeProbe(transport: okTransport).run(
            environment: ["HOME": tempHome.path, "DEEPSEEK_API_KEY": "sk-synthetic-deepseek-12345"],
            now: now
        )
        XCTAssertEqual(okReport.envelope?.balance?.amount, 12.34)
        XCTAssertEqual(okReport.envelope?.balance?.currency, "CNY")
        XCTAssertEqual(okReport.envelope?.balance?.source, "official")
    }

    func testOpenCodeNativeProbeReturnsMissingWithoutPython() async {
        let runner = ProbeRunner(
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil },
            baseEnvironmentProvider: { [:] }
        )
        let report = await runner.report(for: ProviderCatalog.opencode)
        XCTAssertTrue(report.isMissingProbe)
        XCTAssertNil(report.envelope)
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
