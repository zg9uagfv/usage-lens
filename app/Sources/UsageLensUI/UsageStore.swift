import AppKit
import Combine
import Foundation
import UsageLensKit

/// UI 的唯一数据源：定时跑已启用的探针，把结果归约成每个 provider 的状态。
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var states: [Provider: ProviderState]
    @Published public private(set) var isRefreshing = false
    @Published public var selected: Provider

    private let provider: any ProbeProviding
    private let refreshInterval: TimeInterval
    private var loop: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?
    private var credentialGenerations: [Provider: UInt64] = [:]
    private var needsFollowUpRefresh = false
    private var pendingInteractiveProviders: Set<Provider> = []

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

    /// 开发/验收用：USAGE_LENS_REFRESH_SECONDS 覆盖默认 60s 轮询间隔。
    public static var environmentRefreshInterval: TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["USAGE_LENS_REFRESH_SECONDS"],
              let value = Double(raw),
              value >= 1
        else { return 60 }
        return value
    }

    public func state(for provider: Provider) -> ProviderState {
        states[provider] ?? ProviderState(provider: provider)
    }

    /// 菜单栏标签取的数据：跨 provider 最紧张的窗口。
    public var mostTense: TensionWindow? {
        Tension.mostTense(in: ProviderCatalog.active.map(state(for:)))
    }

    /// 菜单栏告警阈值：只依据新鲜、可用的最高用量窗口。
    public var hasCriticalUsage: Bool {
        (mostTense?.percent ?? 0) >= 90
    }

    public func refresh(allowInteractiveAgyAuth: Bool = false) {
        if allowInteractiveAgyAuth {
            pendingInteractiveProviders.insert(ProviderCatalog.agy)
        }
        if isRefreshing {
            needsFollowUpRefresh = true
            return
        }
        guard activeRefreshTask == nil else {
            needsFollowUpRefresh = true
            return
        }
        activeRefreshTask = Task { [weak self] in
            await self?.refreshAll()
        }
    }

    /// 凭据保存或删除后调用：立即作废正在进行的旧凭据刷新结果、清空该厂商旧账号状态，
    /// 并合并触发一次使用新凭据的后续刷新，确保新凭据状态始终胜出。
    public func credentialsDidChange(for provider: Provider, allowInteractiveAuth: Bool = false) {
        if allowInteractiveAuth && provider.id == ProviderCatalog.agy.id {
            pendingInteractiveProviders.insert(provider)
        }
        credentialGenerations[provider, default: 0] &+= 1
        var cleared = ProviderState(provider: provider)
        cleared.isRefreshing = true
        states[provider] = cleared
        needsFollowUpRefresh = true
        if !isRefreshing && activeRefreshTask == nil {
            activeRefreshTask = Task { [weak self] in
                await self?.refreshAll()
            }
        }
    }

    /// 针对 AGY 等依赖外部 CLI / 钥匙串登录态的厂商：当其当前缺少实时窗口且存在登录态诊断或失败时，
    /// 在面板重新打开或应用重新激活时触发一次安全重检，不向其他厂商传递任何凭据。
    public func refreshIfNeededForExternalAuth(for provider: Provider = ProviderCatalog.agy) {
        guard ProviderCatalog.active.contains(provider) else { return }
        let current = state(for: provider)
        guard current.hasLoaded, !current.isMissingProbe, !current.isIncompatibleSchema else { return }
        let needsReauthRefresh = current.windows.isEmpty
            && (current.failureReason != nil || !current.warnings.isEmpty || current.accountLabel == nil)
        if needsReauthRefresh {
            credentialsDidChange(for: provider)
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func start() {
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
        guard !isRefreshing else {
            needsFollowUpRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            activeRefreshTask = nil
        }

        repeat {
            needsFollowUpRefresh = false
            let interactiveProviders = pendingInteractiveProviders
            pendingInteractiveProviders.removeAll()
            let activeProviders = ProviderCatalog.active
            var capturedGenerations: [Provider: UInt64] = [:]
            for provider in activeProviders {
                capturedGenerations[provider] = credentialGenerations[provider, default: 0]
                states[provider]?.isRefreshing = true
            }

            let probe = self.provider
            let nonInteractiveProviders = activeProviders.filter { !interactiveProviders.contains($0) }
            let interactiveBatch = activeProviders.filter { interactiveProviders.contains($0) }

            var reports: [ProbeReport] = []
            if !nonInteractiveProviders.isEmpty {
                let batch = await withTaskGroup(of: ProbeReport.self, returning: [ProbeReport].self) { group in
                    for provider in nonInteractiveProviders {
                        group.addTask {
                            await probe.report(for: provider, allowInteractiveKeychain: false)
                        }
                    }
                    var collected: [ProbeReport] = []
                    for await report in group { collected.append(report) }
                    return collected
                }
                reports.append(contentsOf: batch)
            }
            for provider in interactiveBatch {
                let report = await probe.report(for: provider, allowInteractiveKeychain: true)
                reports.append(report)
            }

            for report in reports {
                let currentGen = credentialGenerations[report.provider, default: 0]
                guard capturedGenerations[report.provider] == currentGen else {
                    // 刷新期间该厂商凭据已变更，丢弃旧凭据时代的结果，避免旧账号数据回填。
                    continue
                }
                guard let previous = states[report.provider] else { continue }
                states[report.provider] = ProviderReducer.apply(report, to: previous)
            }
            debugSummaryIfRequested()
        } while needsFollowUpRefresh
    }

    /// DEBUG_SUMMARY 的一行文案：只有 provider / 状态 / 百分比 / 失败原因，且统一脱敏。
    /// 不输出环境变量，也不输出探针原始 stderr。
    func debugSummaryLine() -> String {
        let details = ProviderCatalog.active.map { provider -> String in
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
        case .incompatible: return "incompatible"
        }
    }
}
