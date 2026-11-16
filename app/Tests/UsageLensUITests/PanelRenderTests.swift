import AppKit
import SwiftUI
import XCTest
@testable import UsageLensKit
@testable import UsageLensUI

// MARK: - 假探针

/// 测试用探针：按 provider 依次吐出预设结果，用完则报「未安装」。
actor SequencedProbeProvider: ProbeProviding {
    private var queue: [Provider: [ProbeReport]]

    init(_ queue: [Provider: [ProbeReport]] = [:]) {
        self.queue = queue
    }

    func report(for provider: Provider) async -> ProbeReport {
        if var reports = queue[provider], !reports.isEmpty {
            let next = reports.removeFirst()
            queue[provider] = reports
            return next
        }
        return ProbeReport(
            provider: provider,
            failure: "未安装探针 \(provider.probeRelativePath)",
            isMissingProbe: true
        )
    }
}

// MARK: - 样本

enum Fixtures {
    static func codexReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: ProbeEnvelope(
                provider: "codex",
                account: ProbeAccount(label: "user@example.com", plan: "plus"),
                generatedAt: now,
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 21,
                        windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60),
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 18,
                        windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(4 * 86_400),
                        basis: "server"
                    ),
                ],
                usage: ProbeUsage(todayTokens: 123_456, source: "local")
            ),
            finishedAt: now
        )
    }

    static func deepseekReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.deepseek,
            envelope: ProbeEnvelope(
                provider: "deepseek",
                windows: [],
                balance: nil,
                spend: ProbeSpend(today: 0.42, window: 3.18, currency: "CNY", source: "estimate"),
                coverage: ProbeCoverage(from: "2026-11-01", to: "2026-11-15", note: "本地日志覆盖，非官方账单"),
                warnings: ["余额需要 API key", "无本地用量记录，花费为 0"]
            ),
            finishedAt: Date()
        )
    }

    static func emptyCodexReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: ProbeEnvelope(provider: "codex", windows: []),
            finishedAt: Date()
        )
    }

    /// 复刻真实探针（feat/probes @ 96b9a97）在本机跑出的形状：
    /// account.label 为 null、两个窗口都已过期，observed_at 是几天前。
    static func expiredCodexReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: ProbeEnvelope(
                provider: "codex",
                account: ProbeAccount(label: nil, plan: "plus"),
                generatedAt: now,
                observedAt: now.addingTimeInterval(-3 * 86_400),
                stale: false,
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 21,
                        windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(-4 * 86_400),
                        expired: true,
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 18,
                        windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(-3 * 86_400),
                        expired: true,
                        basis: "server"
                    ),
                ]
            ),
            finishedAt: now
        )
    }

    /// 契约 stale 的真实可达组合：2 天前的帧、7d 窗口还活着（带倒计时）、5h 窗口已过期。
    static func staleCodexReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: ProbeEnvelope(
                provider: "codex",
                account: ProbeAccount(label: nil, plan: "plus"),
                generatedAt: now,
                observedAt: now.addingTimeInterval(-2 * 86_400),
                stale: true,
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 33,
                        windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(-3600),
                        expired: true,
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 18,
                        windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(3 * 86_400),
                        expired: false,
                        basis: "server"
                    ),
                ]
            ),
            finishedAt: now
        )
    }

    static func incompatibleSchemaReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.codex,
            failure: "探针输出格式不兼容（schema 不符：usage-lens/probe@9）",
            finishedAt: Date(),
            isIncompatibleSchema: true
        )
    }

    static func codexFailureReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.codex,
            failure: "探针超时（>6s）",
            finishedAt: Date()
        )
    }
}

// MARK: - 离屏渲染

/// 本机没有屏幕录制权限，用 ImageRenderer 把真实 SwiftUI 视图渲染成 PNG 作为验收物。
@MainActor
final class PanelRenderTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".preview", isDirectory: true)
    }

    private func makeStore(
        _ provider: any ProbeProviding,
        selected: Provider = ProviderCatalog.codex
    ) -> UsageStore {
        // UsageStore 只刷新已启用的 provider；渲染某个 tab 前要把它加入测试配置。
        var activeIDs = ProviderCatalog.defaultActiveIDs
        if !activeIDs.contains(selected.id) { activeIDs.append(selected.id) }
        UserDefaults.standard.set(activeIDs.joined(separator: ","), forKey: "usageLens.providers")
        return UsageStore(provider: provider, refreshInterval: 3600, selected: selected, autoStart: false)
    }

    @discardableResult
    private func render(_ view: some View, named name: String, background: Color) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let content = view
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)
            .background(background)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            throw XCTSkip("ImageRenderer 在当前环境无法渲染该视图")
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw XCTSkip("PNG 编码失败")
        }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("rendered: \(url.path) \(cgImage.width)x\(cgImage.height)")
        return url
    }

    private var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    func testCodexTabShowsWindows() async throws {
        let store = makeStore(SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.codexReport()]]))
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.codex).status, .ok)
        XCTAssertEqual(store.state(for: ProviderCatalog.codex).windows.count, 2)

        let url = try render(PanelView(store: store), named: "01-codex", background: windowBackground)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertGreaterThan(image.size.width, 300)
        XCTAssertGreaterThan(image.size.height, 200)
    }

    func testDeepSeekTabWithoutKey() async throws {
        let store = makeStore(
            SequencedProbeProvider([ProviderCatalog.deepseek: [Fixtures.deepseekReport()]]),
            selected: ProviderCatalog.deepseek
        )
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.deepseek).status, .warning)
        XCTAssertTrue(store.state(for: ProviderCatalog.deepseek).windows.isEmpty)
        // spend 有值时，矛盾的那条 warning 不展示（列表里只剩余额相关）。
        XCTAssertEqual(store.state(for: ProviderCatalog.deepseek).visibleWarnings, ["余额需要 API key"])

        try render(PanelView(store: store), named: "02-deepseek", background: windowBackground)
    }

    func testMissingProbeShowsNoData() async throws {
        // 探针脚本不在 → 该 provider 显示「无数据」，不是 0%，也不崩。
        let store = makeStore(SequencedProbeProvider(), selected: ProviderCatalog.deepseek)
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.deepseek).status, .missing)

        try render(PanelView(store: store), named: "03-deepseek-missing-probe", background: windowBackground)
    }

    func testStaleCodexKeepsLastValuesDimmed() async throws {
        let provider = SequencedProbeProvider([
            ProviderCatalog.codex: [Fixtures.codexReport(), Fixtures.codexFailureReport()],
        ])
        let store = makeStore(provider)
        await store.refreshAll()
        await store.refreshAll()

        let state = store.state(for: ProviderCatalog.codex)
        XCTAssertEqual(state.status, .stale)
        XCTAssertEqual(state.windows.count, 2)
        XCTAssertEqual(state.failureReason, "探针超时（>6s）")

        try render(PanelView(store: store), named: "04-codex-stale", background: windowBackground)
    }

    func testEmptyProviderShowsNoData() async throws {
        let store = makeStore(SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.emptyCodexReport()]]))
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.codex).status, .empty)

        try render(PanelView(store: store), named: "05-codex-empty", background: windowBackground)
    }

    func testExpiredWindowsRender() async throws {
        // 真实数据里 resets_at 可能在过去：显示「窗口已过期」，不能变成负倒计时。
        let provider = SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.expiredCodexReport()]])
        let store = makeStore(provider)
        await store.refreshAll()

        let state = store.state(for: ProviderCatalog.codex)
        XCTAssertEqual(state.windows.count, 2)
        XCTAssertEqual(state.status, .ok)
        for window in state.windows {
            XCTAssertEqual(UsageFormat.resetCountdown(until: window.resetsAt), "窗口已过期")
        }
        XCTAssertNil(store.mostTense, "过期窗口不许上菜单栏")

        try render(PanelView(store: store), named: "07-codex-expired-windows", background: windowBackground)
    }

    func testDebugSummaryRedactsSecrets() async throws {
        let leaked = ProbeReport(
            provider: ProviderCatalog.codex,
            failure: "probe crash: Authorization: Bearer abc.def-123 / sk-abc123DEF456ghi789"
        )
        let store = makeStore(SequencedProbeProvider([ProviderCatalog.codex: [leaked]]))
        await store.refreshAll()

        let line = store.debugSummaryLine()
        XCTAssertTrue(line.contains("***"))
        XCTAssertFalse(line.contains("abc.def-123"))
        XCTAssertFalse(line.contains("sk-abc123DEF456ghi789"))
        XCTAssertTrue(line.contains("codex=failed"))
    }

    func testStaleDataRendersDimmed() async throws {
        let provider = SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.staleCodexReport()]])
        let store = makeStore(provider)
        await store.refreshAll()

        let state = store.state(for: ProviderCatalog.codex)
        XCTAssertTrue(state.isDataStale)
        XCTAssertEqual(state.status, .warning)
        XCTAssertEqual(state.windows.count, 2)
        XCTAssertTrue(state.windows[0].isExpired())
        XCTAssertFalse(state.windows[1].isExpired())
        XCTAssertNil(store.mostTense, "stale 数据不许上菜单栏")

        try render(PanelView(store: store), named: "08-codex-stale-data", background: windowBackground)
    }

    func testIncompatibleSchemaShowsNoNumbers() async throws {
        let provider = SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.incompatibleSchemaReport()]])
        let store = makeStore(provider)
        await store.refreshAll()

        let state = store.state(for: ProviderCatalog.codex)
        XCTAssertEqual(state.status, .incompatible)
        XCTAssertTrue(state.windows.isEmpty, "schema 不符时不许渲染任何数字")
        XCTAssertNil(state.envelope)
        XCTAssertNil(store.mostTense)

        try render(PanelView(store: store), named: "09-codex-incompatible-schema", background: windowBackground)
    }

    func testMenuBarLabelUsesMostTenseWindow() async throws {
        let provider = SequencedProbeProvider([
            ProviderCatalog.codex: [Fixtures.codexReport()],
            ProviderCatalog.deepseek: [Fixtures.deepseekReport()],
        ])
        let store = makeStore(provider)
        await store.refreshAll()
        XCTAssertEqual(store.mostTense?.compactLabel, "Codex 5h 21%")

        try render(MenuBarLabel(store: store), named: "06-menubar", background: windowBackground)
    }
}
