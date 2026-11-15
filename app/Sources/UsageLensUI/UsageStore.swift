import AppKit
import Combine
import Foundation
import UsageLensKit

/// UI 的唯一数据源：定时跑三个探针，把结果归约成每个 provider 的状态。
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var states: [Provider: ProviderState]
    @Published public private(set) var isRefreshing = false
    @Published public var selected: Provider

    private let provider: any ProbeProviding
    private let refreshInterval: TimeInterval
    private var loop: Task<Void, Never>?

    public init(
        provider: any ProbeProviding = ProbeRunner(),
        refreshInterval: TimeInterval = 60,
        selected: Provider = ProviderCatalog.codex,
        autoStart: Bool = true
    ) {
        self.provider = provider
        self.refreshInterval = refreshInterval
        self.selected = selected

        var initial: [Provider: ProviderState] = [:]
        for provider in ProviderCatalog.all {
            initial[provider] = ProviderState(provider: provider)
        }
        self.states = initial

        if autoStart { start() }
    }

    deinit {
        loop?.cancel()
    }

    public func state(for provider: Provider) -> ProviderState {
        states[provider] ?? ProviderState(provider: provider)
    }

    /// 菜单栏标签取的数据：跨 provider 最紧张的窗口。
    public var mostTense: TensionWindow? {
        Tension.mostTense(in: ProviderCatalog.all.map(state(for:)))
    }

    public func refresh() {
        Task { await refreshAll() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            while !Task.isCancelled {
                let interval = self.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refreshAll()
            }
        }
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for provider in ProviderCatalog.all {
            states[provider]?.isRefreshing = true
        }

        let probe = self.provider
        let reports = await withTaskGroup(of: ProbeReport.self, returning: [ProbeReport].self) { group in
            for provider in ProviderCatalog.all {
                group.addTask { await probe.report(for: provider) }
            }
            var collected: [ProbeReport] = []
            for await report in group { collected.append(report) }
            return collected
        }

        for report in reports {
            guard let previous = states[report.provider] else { continue }
            states[report.provider] = ProviderReducer.apply(report, to: previous)
        }
        isRefreshing = false
        debugSummaryIfRequested()
    }

    /// DEBUG_SUMMARY 的一行文案：只有 provider / 状态 / 百分比 / 失败原因，且统一脱敏。
    /// 不输出环境变量，也不输出探针原始 stderr。
    func debugSummaryLine() -> String {
        let details = ProviderCatalog.all.map { provider -> String in
            let state = state(for: provider)
            let used = state.windows
                .compactMap { $0.usedPercent.map { UsageFormat.percent($0) } }
                .joined(separator: ",")
            var detail = "\(provider.id)=\(statusName(state.status))[used=\(used.isEmpty ? "-" : used)]"
            if let failure = state.failureReason {
                detail += "[err=\(failure)]"
            }
            return detail
        }.joined(separator: " ")
        let label = mostTense?.compactLabel ?? "(无数据，仅图标)"
        return SecretRedactor.redact("[usage-lens] menubar=\"\(label)\" \(details)")
    }

    /// 仅用于验收/排障：把本轮状态打到 stderr（不落盘、不影响正常使用）。
    private func debugSummaryIfRequested() {
        guard ProcessInfo.processInfo.environment["USAGE_LENS_DEBUG_SUMMARY"] == "1" else { return }
        guard let data = (debugSummaryLine() + "\n").data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private func statusName(_ status: ProviderStatus) -> String {
        switch status {
        case .loading: return "loading"
        case .ok: return "ok"
        case .warning: return "warning"
        case .stale: return "stale"
        case .empty: return "empty"
        case .missing: return "missing"
        case .failed: return "failed"
        }
    }
}
