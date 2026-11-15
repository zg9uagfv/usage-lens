import Foundation

// MARK: - 状态

public enum ProviderStatus: Sendable, Equatable {
    /// 还没跑过探针。
    case loading
    /// 有数据，无警告。
    case ok
    /// 有数据，但有 warnings（例如余额需要 API key）。
    case warning
    /// 探针失败，界面保留上次成功值并灰化。
    case stale
    /// 没数据（也没有失败，比如服务无窗口概念）。
    case empty
    /// 探针脚本不存在。
    case missing
    /// 探针失败且没有任何可显示的数据。
    case failed
}

public struct ProviderState: Sendable, Equatable {
    public var provider: Provider
    public var envelope: ProbeEnvelope?
    /// 最近一次拿到数据的时刻（决定「N 分钟前更新」）。
    public var lastDataAt: Date?
    /// 最近一次尝试的时刻。
    public var lastAttemptAt: Date?
    public var failureReason: String?
    public var warnings: [String]
    public var isMissingProbe: Bool
    public var hasLoaded: Bool
    public var isRefreshing: Bool

    public init(provider: Provider) {
        self.provider = provider
        self.envelope = nil
        self.lastDataAt = nil
        self.lastAttemptAt = nil
        self.failureReason = nil
        self.warnings = []
        self.isMissingProbe = false
        self.hasLoaded = false
        self.isRefreshing = false
    }

    public var windows: [ProbeWindow] { envelope?.windows ?? [] }
    public var hasWindows: Bool { !windows.isEmpty }

    /// 失败但还有旧值可显示 = 灰化态。
    public var isStale: Bool { failureReason != nil && envelope != nil && !isMissingProbe }

    public var status: ProviderStatus {
        if isMissingProbe { return .missing }
        guard hasLoaded else { return .loading }
        if failureReason != nil {
            // 有旧值 → 灰化保留；没有旧值 → 明确报错，而不是伪装成「空的」。
            return envelope == nil ? .failed : .stale
        }
        if !hasWindows && envelope?.balance == nil && envelope?.spend == nil {
            return warnings.isEmpty ? .empty : .warning
        }
        return warnings.isEmpty ? .ok : .warning
    }

    public var accountLabel: String? {
        guard let label = envelope?.account?.label, !label.isEmpty else { return nil }
        return label
    }

    public var planLabel: String? {
        guard let plan = envelope?.account?.plan, !plan.isEmpty else { return nil }
        return plan
    }

    /// 给 UI 用的 warning 列表：已有 spend 数据时，过滤掉「没有数据 / 花费为 0」这类自相矛盾的话。
    public var visibleWarnings: [String] {
        guard let spend = envelope?.spend, spend.today != nil || spend.window != nil else {
            return warnings
        }
        return warnings.filter { !WarningFilter.conflictsWithSpend($0) }
    }
}

/// 关键词匹配即可，不做语义分析：探针有时会同时给「估算花费」和「没有用量记录」。
public enum WarningFilter {
    static let spendConflictKeywords = [
        "花费为 0",
        "无本地用量记录",
        "没有本地用量记录",
        "没有 token 用量记录",
        "无 token 用量记录",
        "无法估算花费",
    ]

    public static func conflictsWithSpend(_ warning: String) -> Bool {
        spendConflictKeywords.contains { warning.contains($0) }
    }
}

// MARK: - 归约

public enum ProviderReducer {
    /// 把一次探针结果合进当前状态。
    /// 失败时保留上次的值（灰化由 UI 做），脚本缺失则清空，避免把「没装探针」当旧数据。
    public static func apply(_ report: ProbeReport, to state: ProviderState) -> ProviderState {
        var next = state
        next.isRefreshing = false
        next.lastAttemptAt = report.finishedAt
        next.hasLoaded = true
        next.warnings = report.warnings

        if report.isMissingProbe {
            next.isMissingProbe = true
            next.envelope = nil
            next.failureReason = report.failure
            next.lastDataAt = nil
            return next
        }

        next.isMissingProbe = false

        if let envelope = report.envelope {
            next.envelope = envelope
            next.lastDataAt = report.finishedAt
        }

        next.failureReason = report.failure
        return next
    }
}

// MARK: - 最紧张窗口（菜单栏标签）

public struct TensionWindow: Sendable, Equatable {
    public var provider: Provider
    public var window: ProbeWindow
    public var percent: Double

    public init(provider: Provider, window: ProbeWindow, percent: Double) {
        self.provider = provider
        self.window = window
        self.percent = percent
    }

    /// 窗口短名：优先契约里的 id（`5h` / `7d`），太长的退到 label。
    public var shortWindowName: String {
        let id = window.id
        if !id.isEmpty, !id.hasPrefix("window-"), id.count <= 4 { return id }
        if let label = window.label, !label.isEmpty, label.count <= 6 { return label }
        return "窗口"
    }

    public var compactLabel: String {
        "\(provider.displayName) \(shortWindowName) \(UsageFormat.percent(percent))"
    }

    public var fullLabel: String {
        "\(provider.displayName) · \(window.label ?? window.id) 已用 \(UsageFormat.percent(percent))"
    }
}

public enum Tension {
    /// 跨 provider 取已用百分比最高的窗口；全是 null / 没数据时返回 nil（菜单栏只留图标）。
    public static func mostTense(in states: [ProviderState]) -> TensionWindow? {
        var best: TensionWindow?
        for state in states {
            for window in state.windows {
                guard let used = window.usedPercent, used.isFinite else { continue }
                let clamped = min(max(used, 0), 100)
                if let current = best, current.percent >= clamped { continue }
                best = TensionWindow(provider: state.provider, window: window, percent: clamped)
            }
        }
        return best
    }
}
