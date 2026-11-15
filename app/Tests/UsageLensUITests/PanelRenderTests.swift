import AppKit
import SwiftUI
import XCTest
@testable import UsageLensKit
@testable import UsageLensUI

// MARK: - 假探针

/// 测试用探针：按 provider 依次吐出预设结果，用完则报「未安装」。
final class SequencedProbeProvider: ProbeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Provider: [ProbeReport]]

    init(_ queue: [Provider: [ProbeReport]] = [:]) {
        self.queue = queue
    }

    func report(for provider: Provider) async -> ProbeReport {
        lock.lock()
        defer { lock.unlock() }
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
                ]
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
    /// account.label 为 null、两个窗口的 resets_at 都是过去时间。
    static func expiredCodexReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.codex,
            envelope: ProbeEnvelope(
                provider: "codex",
                account: ProbeAccount(label: nil, plan: "plus"),
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 21,
                        windowSeconds: 18_000,
                        resetsAt: ProbeDate.parse("2026-11-11T05:28:56Z"),
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 18,
                        windowSeconds: 604_800,
                        resetsAt: ProbeDate.parse("2026-11-12T12:55:31Z"),
                        basis: "server"
                    ),
                ]
            ),
            finishedAt: Date()
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
        UsageStore(provider: provider, refreshInterval: 3600, selected: selected, autoStart: false)
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
        XCTAssertEqual(store.mostTense?.compactLabel, "Codex 5h 21%")

        try render(PanelView(store: store), named: "07-codex-expired-windows", background: windowBackground)
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
