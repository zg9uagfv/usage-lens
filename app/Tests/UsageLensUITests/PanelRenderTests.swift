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

/// 可控阻塞探针：用于在单测中确定性地在 refreshAll() 飞行途中触发凭据保存/删除。
actor GatedProbeProvider: ProbeProviding {
    private var reportsByProvider: [Provider: [ProbeReport]]
    private var callCounts: [Provider: Int] = [:]
    private var gateProvider: Provider?
    private var gateOnCall: Int?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStartGatedCall = false
    private var didReleaseGatedCall = false

    init(_ reportsByProvider: [Provider: [ProbeReport]]) {
        self.reportsByProvider = reportsByProvider
    }

    func armGate(provider: Provider, onCall: Int) {
        gateProvider = provider
        gateOnCall = onCall
        didStartGatedCall = false
        didReleaseGatedCall = false
        startedContinuation = nil
        releaseContinuation = nil
    }

    func waitUntilGatedCallStarts() async {
        if didStartGatedCall { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func releaseGatedCall() {
        didReleaseGatedCall = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func calls(for provider: Provider) -> Int {
        callCounts[provider, default: 0]
    }

    func report(for provider: Provider) async -> ProbeReport {
        let callIndex = callCounts[provider, default: 0] + 1
        callCounts[provider] = callIndex

        let report: ProbeReport
        if var list = reportsByProvider[provider], !list.isEmpty {
            report = list.removeFirst()
            reportsByProvider[provider] = list
        } else {
            report = ProbeReport(
                provider: provider,
                failure: "未安装探针 \(provider.probeRelativePath)",
                isMissingProbe: true
            )
        }

        if provider == gateProvider && callIndex == gateOnCall {
            didStartGatedCall = true
            startedContinuation?.resume()
            startedContinuation = nil
            if !didReleaseGatedCall {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }

        return report
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

    static func geminiNeedsAccountReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"]
            ),
            finishedAt: Date()
        )
    }

    static func geminiConfiguredReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: "pro"),
                generatedAt: now,
                observedAt: now,
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 35,
                        windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(3 * 3600),
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 60,
                        windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(4 * 86_400),
                        basis: "server"
                    ),
                ]
            ),
            finishedAt: now
        )
    }

    static func geminiAuthErrorReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "user@gmail.com", plan: nil),
                windows: [],
                error: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号"
            ),
            failure: "Gemini 账号凭据无效或已过期（HTTP 401），请在配置中重新提供账号",
            finishedAt: Date()
        )
    }

    static func agyLiveReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: "agy.user@example.com", plan: "Google AI Pro"),
                generatedAt: now,
                observedAt: now,
                windows: [
                    ProbeWindow(
                        id: "5h",
                        label: "5 小时",
                        usedPercent: 59,
                        windowSeconds: 18_000,
                        resetsAt: now.addingTimeInterval(2 * 3600),
                        basis: "server"
                    ),
                    ProbeWindow(
                        id: "7d",
                        label: "7 天",
                        usedPercent: 15,
                        windowSeconds: 604_800,
                        resetsAt: now.addingTimeInterval(5 * 86_400),
                        basis: "server"
                    ),
                ],
                usage: ProbeUsage(todayTokens: 1_240_500, source: "local")
            ),
            finishedAt: now
        )
    }

    static func agyOfflineLocalTokensReport() -> ProbeReport {
        let now = Date()
        return ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: "agy.user@example.com", plan: nil),
                generatedAt: now,
                observedAt: now,
                windows: [],
                usage: ProbeUsage(todayTokens: 320_000, source: "local"),
                warnings: ["实时查询 AGY 服务端失败（网络不可用），当前仅显示本地今日 tokens"]
            ),
            finishedAt: now
        )
    }

    static func agyMissingAuthReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["未检测到本机 AGY 登录态（本地凭据文件与钥匙串均未找到），请先运行 agy 登录后刷新以查看实时配额"]
            ),
            finishedAt: Date()
        )
    }

    static func agyKeychainDeniedReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["无法访问本机 AGY 钥匙串凭据（访问被拒绝或钥匙串已锁定），请解锁登录钥匙串或运行 agy 重新登录后刷新以查看实时配额"]
            ),
            finishedAt: Date()
        )
    }

    static func agyIsolatedHomeReport() -> ProbeReport {
        ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: nil, plan: nil),
                windows: [],
                warnings: ["未检测到本机 AGY 登录态：当前处于隔离主目录环境，已跳过本机登录钥匙串读取；请在真实用户环境运行 agy 登录或提供 AGY 凭据后刷新以查看实时配额"]
            ),
            finishedAt: Date()
        )
    }

    static func agyExpiredAuthReport() -> ProbeReport {
        let message = "查询 AGY 用量失败：本机 AGY 登录态已过期或认证被拒（HTTP 401），请先运行 agy 重新登录后刷新"
        return ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: "agy.user@example.com", plan: nil),
                windows: [],
                error: message
            ),
            failure: message,
            finishedAt: Date()
        )
    }

    static func agyForbidden403Report() -> ProbeReport {
        let message = "查询 AGY 用量失败：AGY 服务端拒绝访问（HTTP 403），可能是项目权限、策略或配额资格受限，请检查 AGY 账号权限或运行 agy 重新登录后刷新"
        return ProbeReport(
            provider: ProviderCatalog.agy,
            envelope: ProbeEnvelope(
                provider: "agy",
                account: ProbeAccount(label: "agy.user@example.com", plan: nil),
                windows: [],
                error: message
            ),
            failure: message,
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

    /// 用 AppKit NSHostingView + 离屏 NSWindow 渲染真实 SwiftUI 视图（可正确渲染 ScrollView/TextField/SecureField）。
    @discardableResult
    private func renderHosted(
        _ view: some View,
        size: CGSize,
        appearance: NSAppearance? = nil,
        scrollToBottom: Bool = false,
        named name: String,
        inspectView: ((NSView) -> Void)? = nil
    ) throws -> (url: URL, cgImage: CGImage) {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        if let appearance {
            hostingView.appearance = appearance
        }

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        if let appearance {
            window.appearance = appearance
        }
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        hostingView.layoutSubtreeIfNeeded()

        if scrollToBottom, let scrollView = firstDescendant(ofType: NSScrollView.self, in: hostingView),
           let documentView = scrollView.documentView {
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let targetPoint = documentView.isFlipped ? NSPoint(x: 0, y: maxY) : NSPoint(x: 0, y: 0)
            scrollView.contentView.scroll(to: targetPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hostingView.layoutSubtreeIfNeeded()
        }

        inspectView?(hostingView)

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("无法创建 bitmapImageRep")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        guard let cgImage = rep.cgImage,
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("无法编码 hosted PNG")
        }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
        print("rendered-hosted: \(url.path) \(cgImage.width)x\(cgImage.height)")
        return (url, cgImage)
    }

    private func firstDescendant<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func allDescendants<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T {
            result.append(match)
        }
        for subview in view.subviews {
            result.append(contentsOf: allDescendants(ofType: type, in: subview))
        }
        return result
    }

    /// 断言渲染图像非空白/非纯色/非全透明：必须存在足够多与背景色明显不同的可见像素。
    private func assertNonBlankImage(
        _ cgImage: CGImage,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let width = cgImage.width
        let height = cgImage.height
        XCTAssertGreaterThan(width, 100, "\(context): image width too small", file: file, line: line)
        XCTAssertGreaterThan(height, 100, "\(context): image height too small", file: file, line: line)

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("\(context): failed to create CGContext for pixel check", file: file, line: line)
            return
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 取左上角内缩像素作为背景基准，统计与背景显著不同的非透明像素比例。
        let sampleX = min(4, width - 1)
        let sampleY = min(4, height - 1)
        let baseOffset = sampleY * bytesPerRow + sampleX * 4
        let baseR = Int(pixels[baseOffset])
        let baseG = Int(pixels[baseOffset + 1])
        let baseB = Int(pixels[baseOffset + 2])

        var opaqueCount = 0
        var differingCount = 0
        let totalPixels = width * height
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[idx])
            let g = Int(pixels[idx + 1])
            let b = Int(pixels[idx + 2])
            let a = Int(pixels[idx + 3])
            if a > 10 {
                opaqueCount += 1
                let diff = abs(r - baseR) + abs(g - baseG) + abs(b - baseB)
                if diff > 24 {
                    differingCount += 1
                }
            }
        }

        let opaqueRatio = Double(opaqueCount) / Double(totalPixels)
        let contentRatio = Double(differingCount) / Double(totalPixels)
        XCTAssertGreaterThan(opaqueRatio, 0.5, "\(context): image appears transparent (opaqueRatio=\(opaqueRatio))", file: file, line: line)
        XCTAssertGreaterThan(
            contentRatio,
            0.015,
            "\(context): image appears blank or uniform (contentRatio=\(contentRatio), differing=\(differingCount)/\(totalPixels))",
            file: file,
            line: line
        )
    }

    private func appearance(for theme: UsageLensTheme) -> NSAppearance? {
        switch theme {
        case .tech: return NSAppearance(named: .darkAqua)
        case .anime: return NSAppearance(named: .aqua)
        case .system: return NSAppearance(named: .aqua)
        }
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

    func testGeminiNeedsAccountRendersEmptyGuidance() async throws {
        let store = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiNeedsAccountReport()]]),
            selected: ProviderCatalog.gemini
        )
        await store.refreshAll()
        let state = store.state(for: ProviderCatalog.gemini)
        XCTAssertEqual(state.status, .warning)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertNil(state.accountLabel)
        XCTAssertNil(store.mostTense)

        let url = try render(PanelView(store: store), named: "10-gemini-needs-account", background: windowBackground)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertGreaterThan(image.size.width, 300)
        XCTAssertGreaterThan(image.size.height, 200)
    }

    func testGeminiConfiguredShows5hAnd7dWindows() async throws {
        let store = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport()]]),
            selected: ProviderCatalog.gemini
        )
        await store.refreshAll()
        let state = store.state(for: ProviderCatalog.gemini)
        XCTAssertEqual(state.status, .ok)
        XCTAssertEqual(state.accountLabel, "user@gmail.com")
        XCTAssertEqual(state.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(store.mostTense?.compactLabel, "Gemini 7d 60%")

        let url = try render(PanelView(store: store), named: "11-gemini-configured", background: windowBackground)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertGreaterThan(image.size.width, 300)
        XCTAssertGreaterThan(image.size.height, 240)
    }

    func testGeminiAuthErrorRendersFailedAndStaleStates() async throws {
        let failedStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiAuthErrorReport()]]),
            selected: ProviderCatalog.gemini
        )
        await failedStore.refreshAll()
        XCTAssertEqual(failedStore.state(for: ProviderCatalog.gemini).status, .failed)
        try render(PanelView(store: failedStore), named: "12-gemini-auth-failed", background: windowBackground)

        let staleStore = makeStore(
            SequencedProbeProvider([
                ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport(), Fixtures.geminiAuthErrorReport()],
            ]),
            selected: ProviderCatalog.gemini
        )
        await staleStore.refreshAll()
        await staleStore.refreshAll()
        let staleState = staleStore.state(for: ProviderCatalog.gemini)
        XCTAssertEqual(staleState.status, .stale)
        XCTAssertEqual(staleState.windows.count, 2)
        try render(PanelView(store: staleStore), named: "13-gemini-auth-stale", background: windowBackground)
    }

    func testDeleteCredentialsDuringInFlightRefreshClearsAndCoalesces() async {
        let oldReport = ProbeReport(
            provider: ProviderCatalog.gemini,
            envelope: ProbeEnvelope(
                provider: "gemini",
                account: ProbeAccount(label: "old-account@example.com", plan: "pro"),
                generatedAt: Date(),
                observedAt: Date(),
                windows: [
                    ProbeWindow(id: "5h", label: "5 小时", usedPercent: 45, windowSeconds: 18_000, resetsAt: Date().addingTimeInterval(3600), basis: "server"),
                    ProbeWindow(id: "7d", label: "7 天", usedPercent: 72, windowSeconds: 604_800, resetsAt: Date().addingTimeInterval(86_400), basis: "server"),
                ]
            ),
            finishedAt: Date()
        )
        let gated = GatedProbeProvider([
            ProviderCatalog.gemini: [oldReport, oldReport, Fixtures.geminiNeedsAccountReport()],
            ProviderCatalog.codex: [Fixtures.codexReport(), Fixtures.codexReport(), Fixtures.codexReport()],
            ProviderCatalog.deepseek: [Fixtures.deepseekReport(), Fixtures.deepseekReport(), Fixtures.deepseekReport()],
        ])
        let store = makeStore(gated, selected: ProviderCatalog.gemini)

        // 1. 首次刷新建立旧账号状态
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).accountLabel, "old-account@example.com")
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).windows.count, 2)

        // 2. 第 2 次刷新中途暂停（仍持有旧账号结果）
        await gated.armGate(provider: ProviderCatalog.gemini, onCall: 2)
        let inFlight = Task { await store.refreshAll() }
        await gated.waitUntilGatedCallStarts()

        // 3. 在刷新飞行途中删除凭据：旧账号状态必须立即清空
        store.credentialsDidChange(for: ProviderCatalog.gemini)
        XCTAssertNil(store.state(for: ProviderCatalog.gemini).accountLabel)
        XCTAssertTrue(store.state(for: ProviderCatalog.gemini).windows.isEmpty)
        XCTAssertNil(store.state(for: ProviderCatalog.gemini).envelope)

        // 4. 放行旧凭据探针结果：必须被作废，且自动合并执行第 3 次（新凭据状态）刷新
        await gated.releaseGatedCall()
        await inFlight.value

        let calls = await gated.calls(for: ProviderCatalog.gemini)
        XCTAssertEqual(calls, 3, "凭据删除后应合并触发一次后续刷新")
        let finalState = store.state(for: ProviderCatalog.gemini)
        XCTAssertEqual(finalState.status, .warning)
        XCTAssertNil(finalState.accountLabel, "旧账号结果不得回填")
        XCTAssertTrue(finalState.windows.isEmpty, "旧账号窗口不得残留")
    }

    func testSaveCredentialsDuringInFlightRefreshInvalidatesUnconfiguredResult() async {
        let gated = GatedProbeProvider([
            ProviderCatalog.gemini: [
                Fixtures.geminiNeedsAccountReport(),
                Fixtures.geminiNeedsAccountReport(),
                Fixtures.geminiConfiguredReport(),
            ],
            ProviderCatalog.codex: [Fixtures.codexReport(), Fixtures.codexReport(), Fixtures.codexReport()],
            ProviderCatalog.deepseek: [Fixtures.deepseekReport(), Fixtures.deepseekReport(), Fixtures.deepseekReport()],
        ])
        let store = makeStore(gated, selected: ProviderCatalog.gemini)

        // 1. 首次刷新处于未配置状态
        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).status, .warning)
        XCTAssertNil(store.state(for: ProviderCatalog.gemini).accountLabel)

        // 2. 第 2 次刷新飞行途中保存新账号
        await gated.armGate(provider: ProviderCatalog.gemini, onCall: 2)
        let inFlight = Task { await store.refreshAll() }
        await gated.waitUntilGatedCallStarts()

        store.credentialsDidChange(for: ProviderCatalog.gemini)
        await gated.releaseGatedCall()
        await inFlight.value

        let calls = await gated.calls(for: ProviderCatalog.gemini)
        XCTAssertEqual(calls, 3, "保存凭据后应合并触发一次后续刷新")
        let finalState = store.state(for: ProviderCatalog.gemini)
        XCTAssertEqual(finalState.status, .ok)
        XCTAssertEqual(finalState.accountLabel, "user@gmail.com")
        XCTAssertEqual(finalState.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(store.mostTense?.compactLabel, "Gemini 7d 60%")
    }

    func testSettingsAndGeminiPanelAcrossDisplayProfilesAndThemes() async throws {
        let previousTheme = UserDefaults.standard.string(forKey: "usageLens.theme")
        defer {
            if let previousTheme {
                UserDefaults.standard.set(previousTheme, forKey: "usageLens.theme")
            } else {
                UserDefaults.standard.removeObject(forKey: "usageLens.theme")
            }
        }

        let launchAtLogin = LaunchAtLoginManager()
        let profiles: [(String, DisplayScaleMetrics)] = [
            ("compact", DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))),
            ("baseline", DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900), physicalSizeMM: CGSize(width: 286, height: 179))),
            ("mbp16", DisplayScaleMetrics.make(displaySize: CGSize(width: 1728, height: 1117), physicalSizeMM: CGSize(width: 345, height: 223))),
            ("monitor27", DisplayScaleMetrics.make(displaySize: CGSize(width: 1920, height: 1080), visibleSize: CGSize(width: 1920, height: 1020), physicalSizeMM: CGSize(width: 597, height: 336))),
        ]

        // 预备三个 Gemini 面板状态
        let needsAccountStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiNeedsAccountReport()]]),
            selected: ProviderCatalog.gemini
        )
        await needsAccountStore.refreshAll()

        let configuredStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport()]]),
            selected: ProviderCatalog.gemini
        )
        await configuredStore.refreshAll()

        let authErrorStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiAuthErrorReport()]]),
            selected: ProviderCatalog.gemini
        )
        await authErrorStore.refreshAll()

        for theme in UsageLensTheme.allCases {
            UserDefaults.standard.set(theme.rawValue, forKey: "usageLens.theme")
            let nsAppearance = appearance(for: theme)

            for (label, metrics) in profiles {
                // 1. Settings（未配置 Gemini 展开）：必须通过 NSHostingView 渲染 ScrollView + SecureField/TextField，且非空白
                let unconfiguredSettings = SettingsPanelView(
                    launchAtLogin: launchAtLogin,
                    hasSavedAPIKey: false,
                    savedGeminiAccountEmail: .some(nil),
                    initialExpandedProviderID: ProviderCatalog.gemini.id
                ).environment(\.displayScaleMetrics, metrics)
                let (_, unconfiguredImg) = try renderHosted(
                    unconfiguredSettings,
                    size: metrics.settingsWindowSize,
                    appearance: nsAppearance,
                    scrollToBottom: true,
                    named: "14-settings-gemini-unconfigured-\(theme.rawValue)-\(label)",
                    inspectView: { root in
                        XCTAssertNotNil(self.firstDescendant(ofType: NSScrollView.self, in: root))
                        let secureFields = self.allDescendants(ofType: NSSecureTextField.self, in: root)
                        XCTAssertFalse(secureFields.isEmpty, "未配置 Gemini 表单应包含 SecureField (\(theme.rawValue)/\(label))")
                    }
                )
                assertNonBlankImage(unconfiguredImg, context: "settings-unconfigured-\(theme.rawValue)-\(label)")

                // 2. Settings（已手动配置 Gemini 展开）：展示脱敏邮箱 + 固定掩码，不得回填明文邮箱或令牌，且非空白
                let configuredSettings = SettingsPanelView(
                    launchAtLogin: launchAtLogin,
                    hasSavedAPIKey: false,
                    geminiCredentialSource: .manualKeychain(email: "user@gmail.com"),
                    initialExpandedProviderID: ProviderCatalog.gemini.id
                ).environment(\.displayScaleMetrics, metrics)
                let (_, configuredImg) = try renderHosted(
                    configuredSettings,
                    size: metrics.settingsWindowSize,
                    appearance: nsAppearance,
                    scrollToBottom: true,
                    named: "15-settings-gemini-configured-\(theme.rawValue)-\(label)",
                    inspectView: { root in
                        let fields = self.allDescendants(ofType: NSTextField.self, in: root)
                        XCTAssertTrue(
                            fields.contains { $0.stringValue == "*****@gmail.com" },
                            "已配置 Settings 应展示脱敏后的账号邮箱 (\(theme.rawValue)/\(label))"
                        )
                        XCTAssertFalse(
                            fields.contains { $0.stringValue.contains("user@gmail.com") },
                            "已配置 Settings 不得展示明文账号邮箱 (\(theme.rawValue)/\(label))"
                        )
                        XCTAssertTrue(
                            fields.contains { $0.stringValue == "****************" },
                            "已配置 Settings 应展示固定掩码令牌 (\(theme.rawValue)/\(label))"
                        )
                    }
                )
                assertNonBlankImage(configuredImg, context: "settings-configured-\(theme.rawValue)-\(label)")

                // 2b. Settings（自动复用本机登录态展开）：展示脱敏后的本机邮箱 + 手动覆盖表单，且非空白
                let localCLISettings = SettingsPanelView(
                    launchAtLogin: launchAtLogin,
                    hasSavedAPIKey: false,
                    geminiCredentialSource: .localCLI(email: "local@gmail.com"),
                    initialExpandedProviderID: ProviderCatalog.gemini.id
                ).environment(\.displayScaleMetrics, metrics)
                let (_, localCLIImg) = try renderHosted(
                    localCLISettings,
                    size: metrics.settingsWindowSize,
                    appearance: nsAppearance,
                    scrollToBottom: true,
                    named: "15b-settings-gemini-local-cli-\(theme.rawValue)-\(label)",
                    inspectView: { root in
                        XCTAssertNotNil(self.firstDescendant(ofType: NSScrollView.self, in: root))
                        let fields = self.allDescendants(ofType: NSTextField.self, in: root)
                        XCTAssertTrue(
                            fields.contains { $0.stringValue == "*****@gmail.com" },
                            "本机复用 Settings 应展示脱敏后的本机账号邮箱 (\(theme.rawValue)/\(label))"
                        )
                        XCTAssertFalse(
                            fields.contains { $0.stringValue.contains("local@gmail.com") },
                            "本机复用 Settings 不得展示明文本机账号邮箱 (\(theme.rawValue)/\(label))"
                        )
                        let secureFields = self.allDescendants(ofType: NSSecureTextField.self, in: root)
                        XCTAssertFalse(
                            secureFields.isEmpty,
                            "本机复用 Settings 应保留手动覆盖表单的 SecureField (\(theme.rawValue)/\(label))"
                        )
                    }
                )
                assertNonBlankImage(localCLIImg, context: "settings-local-cli-\(theme.rawValue)-\(label)")

                // 3. Gemini 面板三态（needs-account / configured 5h+7d / auth-error）在 4 档显示配置 × 3 主题下全部验证非空白
                let panelHeight = metrics.scaledDimension(320, minimum: 260)
                let panelSize = CGSize(width: metrics.panelWidth, height: panelHeight)

                let (_, needsImg) = try renderHosted(
                    PanelView(store: needsAccountStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "16-panel-gemini-needs-account-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(needsImg, context: "panel-needs-account-\(theme.rawValue)-\(label)")

                let (_, okImg) = try renderHosted(
                    PanelView(store: configuredStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "17-panel-gemini-configured-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(okImg, context: "panel-configured-\(theme.rawValue)-\(label)")

                let (_, errImg) = try renderHosted(
                    PanelView(store: authErrorStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "18-panel-gemini-auth-error-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(errImg, context: "panel-auth-error-\(theme.rawValue)-\(label)")
            }
        }
    }

    /// 验收 AGY Codex-style 面板（5h/7d 窗口 + Google AI Pro 徽章 + 今日 tokens 卡片、离线回退）
    /// 与 Settings 中 AGY 厂商行在 4 档 DisplayScaleMetrics × 3 主题下的真实 AppKit 离屏渲染。
    func testAgyPanelAndSettingsHostedRenderAcrossThemesAndScales() async throws {
        let previousTheme = UserDefaults.standard.string(forKey: "usageLens.theme")
        let previousProviders = UserDefaults.standard.string(forKey: "usageLens.providers")
        defer {
            if let previousTheme {
                UserDefaults.standard.set(previousTheme, forKey: "usageLens.theme")
            } else {
                UserDefaults.standard.removeObject(forKey: "usageLens.theme")
            }
            if let previousProviders {
                UserDefaults.standard.set(previousProviders, forKey: "usageLens.providers")
            } else {
                UserDefaults.standard.removeObject(forKey: "usageLens.providers")
            }
        }

        let launchAtLogin = LaunchAtLoginManager()
        let profiles: [(String, DisplayScaleMetrics)] = [
            ("compact", DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))),
            ("standard", DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900), physicalSizeMM: CGSize(width: 286, height: 179))),
            ("comfortable", DisplayScaleMetrics.make(displaySize: CGSize(width: 1728, height: 1117), physicalSizeMM: CGSize(width: 345, height: 223))),
            ("large", DisplayScaleMetrics.make(displaySize: CGSize(width: 1920, height: 1080), visibleSize: CGSize(width: 1920, height: 1020), physicalSizeMM: CGSize(width: 597, height: 336))),
        ]

        let agyLiveStore = makeStore(
            SequencedProbeProvider([
                ProviderCatalog.codex: [Fixtures.codexReport()],
                ProviderCatalog.agy: [Fixtures.agyLiveReport()],
                ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport()],
            ]),
            selected: ProviderCatalog.agy
        )
        await agyLiveStore.refreshAll()

        let agyFallbackStore = makeStore(
            SequencedProbeProvider([
                ProviderCatalog.agy: [Fixtures.agyOfflineLocalTokensReport()],
            ]),
            selected: ProviderCatalog.agy
        )
        await agyFallbackStore.refreshAll()

        for theme in UsageLensTheme.allCases {
            UserDefaults.standard.set(theme.rawValue, forKey: "usageLens.theme")
            let nsAppearance = appearance(for: theme)

            for (label, metrics) in profiles {
                let panelHeight = metrics.scaledDimension(360, minimum: 280)
                let panelSize = CGSize(width: metrics.panelWidth, height: panelHeight)

                let (_, liveImg) = try renderHosted(
                    PanelView(store: agyLiveStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "19-panel-agy-live-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(liveImg, context: "panel-agy-live-\(theme.rawValue)-\(label)")

                let (_, fallbackImg) = try renderHosted(
                    PanelView(store: agyFallbackStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "20-panel-agy-fallback-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(fallbackImg, context: "panel-agy-fallback-\(theme.rawValue)-\(label)")

                let settingsView = SettingsPanelView(
                    launchAtLogin: launchAtLogin,
                    hasSavedAPIKey: false,
                    geminiCredentialSource: .unconfigured
                ).environment(\.displayScaleMetrics, metrics)
                let (_, settingsImg) = try renderHosted(
                    settingsView,
                    size: metrics.settingsWindowSize,
                    appearance: nsAppearance,
                    scrollToBottom: true,
                    named: "21-settings-agy-active-\(theme.rawValue)-\(label)",
                    inspectView: { root in
                        XCTAssertNotNil(self.firstDescendant(ofType: NSScrollView.self, in: root))
                    }
                )
                assertNonBlankImage(settingsImg, context: "settings-agy-active-\(theme.rawValue)-\(label)")
            }
        }
    }

    /// 验收 AGY 认证诊断空态（missing / denied / isolated / expired）渲染与文案隔离：
    /// 1. 明确命名 AGY 并给出可执行操作，绝不提示用户去 Gemini 配置填令牌；
    /// 2. 不含合成密钥痕迹；
    /// 3. 外部认证态变化触发 AGY 刷新时不干扰 Gemini 已加载数据。
    func testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance() async throws {
        let metrics = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            physicalSizeMM: CGSize(width: 286, height: 179)
        )
        let panelSize = CGSize(width: metrics.panelWidth, height: metrics.scaledDimension(340, minimum: 280))

        let cases: [(name: String, report: ProbeReport, expectedStatus: ProviderStatus)] = [
            ("22-panel-agy-missing", Fixtures.agyMissingAuthReport(), .warning),
            ("23-panel-agy-denied", Fixtures.agyKeychainDeniedReport(), .warning),
            ("24-panel-agy-isolated", Fixtures.agyIsolatedHomeReport(), .warning),
            ("25-panel-agy-expired", Fixtures.agyExpiredAuthReport(), .failed),
            ("26-panel-agy-forbidden-403", Fixtures.agyForbidden403Report(), .failed),
        ]

        for item in cases {
            let store = makeStore(
                SequencedProbeProvider([
                    ProviderCatalog.agy: [item.report],
                    ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport()],
                ]),
                selected: ProviderCatalog.agy
            )
            await store.refreshAll()
            let state = store.state(for: ProviderCatalog.agy)
            XCTAssertEqual(state.status, item.expectedStatus, item.name)
            XCTAssertTrue(state.windows.isEmpty, item.name)

            let combinedText = ([state.failureReason].compactMap { $0 } + state.warnings).joined(separator: " ")
            XCTAssertTrue(combinedText.contains("AGY"), "\(item.name) must name AGY")
            XCTAssertFalse(combinedText.contains("Gemini"), "\(item.name) must not direct users to Gemini settings")
            XCTAssertFalse(combinedText.contains("请先在配置中提供"), "\(item.name) must not direct users to manual Gemini config")
            XCTAssertFalse(combinedText.contains("ya29."), "\(item.name) must not leak access tokens")
            XCTAssertFalse(combinedText.contains("1//"), "\(item.name) must not leak refresh tokens")

            let (_, img) = try renderHosted(
                PanelView(store: store).environment(\.displayScaleMetrics, metrics),
                size: panelSize,
                appearance: NSAppearance(named: .aqua),
                named: item.name
            )
            assertNonBlankImage(img, context: item.name)

            // Gemini 既有配额显示保持完整不受影响
            let geminiState = store.state(for: ProviderCatalog.gemini)
            XCTAssertEqual(geminiState.status, .ok)
            XCTAssertEqual(geminiState.windows.map(\.id), ["5h", "7d"])
        }
    }

    func testRefreshIfNeededForExternalAuthRefreshesAgyWithoutDisturbingGemini() async {
        let gated = GatedProbeProvider([
            ProviderCatalog.agy: [Fixtures.agyKeychainDeniedReport(), Fixtures.agyLiveReport()],
            ProviderCatalog.gemini: [Fixtures.geminiConfiguredReport(), Fixtures.geminiConfiguredReport()],
            ProviderCatalog.codex: [Fixtures.codexReport(), Fixtures.codexReport()],
        ])
        let store = makeStore(gated, selected: ProviderCatalog.agy)

        await store.refreshAll()
        XCTAssertEqual(store.state(for: ProviderCatalog.agy).status, .warning)
        XCTAssertTrue(store.state(for: ProviderCatalog.agy).windows.isEmpty)
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).status, .ok)
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).windows.map(\.id), ["5h", "7d"])

        // 触发外部认证重检：AGY 立即刷新拿到 5h/7d，Gemini 状态保持健康
        store.refreshIfNeededForExternalAuth(for: ProviderCatalog.agy)
        for _ in 0..<40 {
            if !store.isRefreshing && store.state(for: ProviderCatalog.agy).windows.count == 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.state(for: ProviderCatalog.agy).status, .ok)
        XCTAssertEqual(store.state(for: ProviderCatalog.agy).windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).status, .ok)
        XCTAssertEqual(store.state(for: ProviderCatalog.gemini).windows.map(\.id), ["5h", "7d"])
    }

    /// 验收 UI 层面的首次使用与登录指导文案：
    /// 1. 直接断言 ProviderDetailView / FooterBar / SettingsPanelView / AboutPanelView 的实际可见 UI 文案，
    ///    覆盖 AGY (missing/denied/isolated/expired/403 + local-only)、Gemini (未配置/CLI/手动覆盖)、
    ///    Codex/OpenCode/DeepSeek、升级添加 AGY 指引及关于页；
    /// 2. 强制确保所有 AGY 空态可见文案均含 `agy acp --login`、无 `Gemini`、无 `agy login`、无钥匙串内部 service 名；
    /// 3. 在 3 主题 × 4 显示档位下渲染新增指引与关于页，确认滚动与布局正常。
    func testUserUsageGuidanceCopyAndHostedRenderAcrossThemesAndScales() async throws {
        // 1. AGY 空态（missing / denied / isolated / expired / 403）实际 UI 文案
        let agyReports: [(String, ProbeReport)] = [
            ("missing", Fixtures.agyMissingAuthReport()),
            ("denied", Fixtures.agyKeychainDeniedReport()),
            ("isolated", Fixtures.agyIsolatedHomeReport()),
            ("expired", Fixtures.agyExpiredAuthReport()),
            ("forbidden403", Fixtures.agyForbidden403Report()),
        ]
        for (name, report) in agyReports {
            let store = makeStore(
                SequencedProbeProvider([ProviderCatalog.agy: [report]]),
                selected: ProviderCatalog.agy
            )
            await store.refreshAll()
            let detail = ProviderDetailView(state: store.state(for: ProviderCatalog.agy))
            let uiText = [detail.emptyTitle, detail.emptyReason ?? "", detail.emptyGuidanceHint ?? ""].joined(separator: " ")

            XCTAssertTrue(uiText.contains("AGY"), "AGY(\(name)) UI 应明确命名 AGY")
            XCTAssertTrue(uiText.contains("agy acp --login"), "AGY(\(name)) UI 应给出有效登录命令 agy acp --login")
            XCTAssertTrue(uiText.contains("无需手动复制 OAuth token"), "AGY(\(name)) UI 应说明无需手动复制 token")
            XCTAssertTrue(uiText.contains("重新检测 AGY"), "AGY(\(name)) UI 应提示重新检测步骤")
            XCTAssertFalse(uiText.localizedCaseInsensitiveContains("gemini"), "AGY(\(name)) 空态 UI 不得出现 Gemini 指导或内部 service 名")
            XCTAssertFalse(uiText.contains("agy login"), "AGY(\(name)) UI 不得出现无效命令 agy login")
            XCTAssertFalse(uiText.contains("前往配置"), "AGY(\(name)) UI 不得引导去手动账号配置")
        }

        // AGY 有本地今日 tokens 但无实时配额：保留本地数据与无 Gemini 提示
        let agyLocalStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.agy: [Fixtures.agyOfflineLocalTokensReport()]]),
            selected: ProviderCatalog.agy
        )
        await agyLocalStore.refreshAll()
        let agyLocalDetail = ProviderDetailView(state: agyLocalStore.state(for: ProviderCatalog.agy))
        XCTAssertTrue(agyLocalDetail.noWindowText.contains("agy acp --login"))
        XCTAssertFalse(agyLocalDetail.noWindowText.localizedCaseInsensitiveContains("gemini"))
        XCTAssertEqual(agyLocalStore.state(for: ProviderCatalog.agy).envelope?.usage?.todayTokens, 320_000)

        // 2. Gemini 未配置空态实际 UI 文案：优先 gemini 浏览器登录 + 自动复用 + AGY 切换/升级指引 + 可选高级覆盖
        let geminiStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.gemini: [Fixtures.geminiNeedsAccountReport()]]),
            selected: ProviderCatalog.gemini
        )
        await geminiStore.refreshAll()
        let geminiDetail = ProviderDetailView(state: geminiStore.state(for: ProviderCatalog.gemini))
        let geminiUIText = [geminiDetail.emptyTitle, geminiDetail.emptyReason ?? "", geminiDetail.emptyGuidanceHint ?? ""].joined(separator: " ")
        XCTAssertTrue(geminiUIText.contains("gemini"), "Gemini 空态应提示终端运行 gemini")
        XCTAssertTrue(geminiUIText.contains("浏览器 Google 登录"), "Gemini 空态应提示浏览器 Google 登录")
        XCTAssertTrue(geminiUIText.contains("~/.gemini/oauth_creds.json"), "Gemini 空态应说明自动复用路径")
        XCTAssertTrue(geminiUIText.contains("刷新"), "Gemini 空态应提示登录后刷新")
        XCTAssertTrue(geminiUIText.contains("AGY"), "Gemini 空态应提醒 Antigravity 用户切到 AGY")
        XCTAssertTrue(geminiUIText.contains("添加模型厂商 → 添加 AGY"), "Gemini 空态应给出缺少 AGY 时的恢复路径")
        XCTAssertTrue(geminiUIText.contains("可选高级手动覆盖"), "Gemini 空态应将手动配置标注为可选高级覆盖")

        // 3. Codex / OpenCode / DeepSeek 空态与页脚帮助文案
        let codexEmptyStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.emptyCodexReport()]]),
            selected: ProviderCatalog.codex
        )
        await codexEmptyStore.refreshAll()
        XCTAssertTrue((ProviderDetailView(state: codexEmptyStore.state(for: ProviderCatalog.codex)).emptyReason ?? "").contains("codex"))

        let opencodeMissing = await OpenCodeNativeProbe().run(environment: [:])
        let opencodeStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.opencode: [opencodeMissing]]),
            selected: ProviderCatalog.opencode
        )
        await opencodeStore.refreshAll()
        let opencodeDetail = ProviderDetailView(state: opencodeStore.state(for: ProviderCatalog.opencode))
        XCTAssertTrue(opencodeStore.state(for: ProviderCatalog.opencode).isMissingProbe)
        XCTAssertTrue(opencodeDetail.emptyTitle.contains("暂未接入原生用量探针"))
        let opencodeReason = opencodeDetail.emptyReason ?? ""
        XCTAssertTrue(opencodeReason.contains("预留标签"))
        XCTAssertTrue(opencodeReason.contains("无需填写 token"))
        XCTAssertTrue(opencodeReason.contains("配置"))
        XCTAssertFalse(opencodeReason.contains("probes/opencode.py"), "OpenCode 真实占位态不应提示过时的 Python 探针路径")

        let deepseekEmpty = ProbeReport(
            provider: ProviderCatalog.deepseek,
            envelope: ProbeEnvelope(provider: "deepseek", windows: []),
            finishedAt: Date()
        )
        let deepseekStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.deepseek: [deepseekEmpty]]),
            selected: ProviderCatalog.deepseek
        )
        await deepseekStore.refreshAll()
        let deepseekReason = ProviderDetailView(state: deepseekStore.state(for: ProviderCatalog.deepseek)).emptyReason ?? ""
        XCTAssertTrue(deepseekReason.contains("API Key"))
        XCTAssertTrue(deepseekReason.contains("估算"))

        XCTAssertTrue(FooterBar.refreshHelpText.contains("刷新"))
        XCTAssertTrue(FooterBar.settingsHelpText.contains("添加模型厂商"))
        XCTAssertTrue(FooterBar.settingsHelpText.contains("使用说明"))

        // 4. 配置页使用说明 + Gemini 三态与高级覆盖文案 + 关于页五厂商范围
        let settingsGuideText = ([SettingsPanelView.usageGuideHeadline] + SettingsPanelView.usageGuideItems.map { "\($0.title) \($0.detail)" }).joined(separator: "\n")
        XCTAssertTrue(settingsGuideText.contains("agy acp --login"))
        XCTAssertTrue(settingsGuideText.contains("添加模型厂商 → 添加 AGY"))
        XCTAssertTrue(settingsGuideText.contains("~/.gemini/oauth_creds.json"))
        XCTAssertTrue(settingsGuideText.contains("codex"))
        XCTAssertTrue(settingsGuideText.contains("OpenCode"))
        XCTAssertTrue(settingsGuideText.contains("预留标签"))
        XCTAssertTrue(settingsGuideText.contains("原生用量探针尚未接入"))
        XCTAssertTrue(settingsGuideText.contains("DeepSeek"))
        XCTAssertTrue(settingsGuideText.contains("估算"))
        XCTAssertFalse(settingsGuideText.contains("agy login"))

        XCTAssertTrue(SettingsPanelView.geminiLocalAutoReuseSummary.contains("gemini"))
        XCTAssertTrue(SettingsPanelView.geminiLocalAutoReuseSummary.contains("~/.gemini/oauth_creds.json"))
        XCTAssertTrue(SettingsPanelView.geminiManualOverrideHeading.contains("可选高级手动覆盖"))
        XCTAssertTrue(SettingsPanelView.geminiManualOverrideHeading.contains("勿填入 API Key"))
        XCTAssertTrue(SettingsPanelView.geminiManualOverrideCaption.contains("Google Cloud Project ID"))

        for providerName in ["Codex", "AGY", "Gemini", "OpenCode", "DeepSeek"] {
            XCTAssertTrue(AboutPanelView.productSummary.contains(providerName), "关于页产品范围应包含 \(providerName)")
        }

        // 5. 跨 3 主题 × 4 显示档位验证实际托管渲染（About + 新增指导后的 Settings 滚动 + AGY/Gemini 空态）
        let previousTheme = UserDefaults.standard.string(forKey: "usageLens.theme")
        defer {
            if let previousTheme {
                UserDefaults.standard.set(previousTheme, forKey: "usageLens.theme")
            } else {
                UserDefaults.standard.removeObject(forKey: "usageLens.theme")
            }
        }
        let launchAtLogin = LaunchAtLoginManager()
        let profiles: [(String, DisplayScaleMetrics)] = [
            ("compact", DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))),
            ("standard", DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900), physicalSizeMM: CGSize(width: 286, height: 179))),
            ("comfortable", DisplayScaleMetrics.make(displaySize: CGSize(width: 1728, height: 1117), physicalSizeMM: CGSize(width: 345, height: 223))),
            ("large", DisplayScaleMetrics.make(displaySize: CGSize(width: 1920, height: 1080), visibleSize: CGSize(width: 1920, height: 1020), physicalSizeMM: CGSize(width: 597, height: 336))),
        ]
        let agyMissingStore = makeStore(
            SequencedProbeProvider([ProviderCatalog.agy: [Fixtures.agyMissingAuthReport()]]),
            selected: ProviderCatalog.agy
        )
        await agyMissingStore.refreshAll()

        for theme in UsageLensTheme.allCases {
            UserDefaults.standard.set(theme.rawValue, forKey: "usageLens.theme")
            let nsAppearance = appearance(for: theme)
            for (label, metrics) in profiles {
                let (_, aboutImg) = try renderHosted(
                    AboutPanelView().environment(\.displayScaleMetrics, metrics),
                    size: metrics.aboutWindowSize,
                    appearance: nsAppearance,
                    named: "27-about-five-providers-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(aboutImg, context: "about-\(theme.rawValue)-\(label)")

                let settingsView = SettingsPanelView(
                    launchAtLogin: launchAtLogin,
                    hasSavedAPIKey: false,
                    geminiCredentialSource: .unconfigured,
                    initialExpandedProviderID: ProviderCatalog.gemini.id
                ).environment(\.displayScaleMetrics, metrics)
                let (_, settingsImg) = try renderHosted(
                    settingsView,
                    size: metrics.settingsWindowSize,
                    appearance: nsAppearance,
                    scrollToBottom: true,
                    named: "28-settings-guidance-\(theme.rawValue)-\(label)",
                    inspectView: { root in
                        let scroll = self.firstDescendant(ofType: NSScrollView.self, in: root)
                        XCTAssertNotNil(scroll)
                        if let docHeight = scroll?.documentView?.frame.height {
                            XCTAssertGreaterThan(docHeight, metrics.settingsWindowSize.height * 0.5)
                        }
                    }
                )
                assertNonBlankImage(settingsImg, context: "settings-guidance-\(theme.rawValue)-\(label)")

                let panelSize = CGSize(width: metrics.panelWidth, height: metrics.scaledDimension(380, minimum: 300))
                let (_, agyImg) = try renderHosted(
                    PanelView(store: agyMissingStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "29-panel-agy-guidance-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(agyImg, context: "panel-agy-guidance-\(theme.rawValue)-\(label)")

                let (_, geminiImg) = try renderHosted(
                    PanelView(store: geminiStore).environment(\.displayScaleMetrics, metrics),
                    size: panelSize,
                    appearance: nsAppearance,
                    named: "30-panel-gemini-guidance-\(theme.rawValue)-\(label)"
                )
                assertNonBlankImage(geminiImg, context: "panel-gemini-guidance-\(theme.rawValue)-\(label)")
            }
        }
    }

    func testPanelViewMasksAccountLabelsAcrossProviders() async throws {
        let metrics = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            physicalSizeMM: CGSize(width: 286, height: 179)
        )
        let panelSize = CGSize(width: metrics.panelWidth, height: metrics.scaledDimension(340, minimum: 280))

        let cases: [(name: String, provider: Provider, report: ProbeReport, expectedMasked: String, forbiddenPlaintext: [String])] = [
            (
                "31-panel-codex-masked",
                ProviderCatalog.codex,
                Fixtures.codexReport(),
                "*****@example.com",
                ["user@example.com", "user@gmail.com", "agy.user@example.com"]
            ),
            (
                "32-panel-gemini-masked",
                ProviderCatalog.gemini,
                Fixtures.geminiConfiguredReport(),
                "*****@gmail.com",
                ["user@gmail.com", "user@example.com", "agy.user@example.com"]
            ),
            (
                "33-panel-agy-masked",
                ProviderCatalog.agy,
                Fixtures.agyLiveReport(),
                "*****@example.com",
                ["agy.user@example.com", "user@gmail.com", "user@example.com"]
            ),
        ]

        for item in cases {
            let store = makeStore(
                SequencedProbeProvider([item.provider: [item.report]]),
                selected: item.provider
            )
            await store.refreshAll()

            let state = store.state(for: item.provider)
            let displayed = ProviderDetailView(state: state).displayedAccountText
            XCTAssertEqual(displayed, item.expectedMasked, item.name)
            for plaintext in item.forbiddenPlaintext {
                XCTAssertFalse(
                    displayed.contains(plaintext),
                    "\(item.name) must never render plaintext account \(plaintext)"
                )
            }

            let (_, img) = try renderHosted(
                PanelView(store: store).environment(\.displayScaleMetrics, metrics),
                size: panelSize,
                appearance: NSAppearance(named: .aqua),
                named: item.name
            )
            assertNonBlankImage(img, context: item.name)
        }

        let agyMissing = makeStore(
            SequencedProbeProvider([ProviderCatalog.agy: [Fixtures.agyMissingAuthReport()]]),
            selected: ProviderCatalog.agy
        )
        await agyMissing.refreshAll()
        XCTAssertEqual(ProviderDetailView(state: agyMissing.state(for: ProviderCatalog.agy)).displayedAccountText, "未检测到 AGY 账号")

        let codexEmpty = makeStore(
            SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.emptyCodexReport()]]),
            selected: ProviderCatalog.codex
        )
        await codexEmpty.refreshAll()
        XCTAssertEqual(ProviderDetailView(state: codexEmpty.state(for: ProviderCatalog.codex)).displayedAccountText, "未提供账号")
    }
}
