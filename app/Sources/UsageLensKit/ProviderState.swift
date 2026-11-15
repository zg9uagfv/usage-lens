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
    /// schema 不符：输出整份作废，不展示任何数字。
    case incompatible
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
    public var isIncompatibleSchema: Bool
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
        self.isIncompatibleSchema = false
        self.hasLoaded = false
        self.isRefreshing = false
    }

    public var windows: [ProbeWindow] { envelope?.windows ?? [] }
    public var hasWindows: Bool { !windows.isEmpty }

    /// 失败但还有旧值可显示 = 灰化态。
    public var isStale: Bool { failureReason != nil && envelope != nil && !isMissingProbe }

    /// 契约的 stale：数据源帧太旧（探针明确置位，不靠 warnings 兜底）。
    public var isDataStale: Bool { envelope?.dataIsStale ?? false }

    /// 需要灰化展示的条件：失败保留的旧值，或探针明确标记的数据陈旧。
    public var isDimmed: Bool { isStale || isDataStale }

    /// 「数据 X 天前」用的时间：只认探针给的 observed_at。
    /// 缺失时不编造「刚刚」，宁可不写天数（老探针联调时就是这种情况）。
    public var observedAt: Date? { envelope?.observedAt }

    public var status: ProviderStatus {
        if isMissingProbe { return .missing }
        guard hasLoaded else { return .loading }
        if isIncompatibleSchema { return .incompatible }
        if failureReason != nil {
            // 有旧值 → 灰化保留；没有旧值 → 明确报错，而不是伪装成「空的」。
            return envelope == nil ? .failed : .stale
        }
        if !hasWindows && envelope?.balance == nil && envelope?.spend == nil && envelope?.usage == nil {
            return (warnings.isEmpty && !isDataStale) ? .empty : .warning
        }
        return (warnings.isEmpty && !isDataStale) ? .ok : .warning
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
            next.isIncompatibleSchema = false
            next.envelope = nil
            next.failureReason = report.failure
            next.lastDataAt = nil
            return next
        }

        if report.isIncompatibleSchema {
            // 整份作废：不保留旧值，也不出现「上次成功值」。
            next.isMissingProbe = false
            next.isIncompatibleSchema = true
            next.envelope = nil
            next.failureReason = report.failure ?? "探针输出格式不兼容"
            next.lastDataAt = nil
            return next
        }

        next.isMissingProbe = false
        next.isIncompatibleSchema = false

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
    /// 跨 provider 取已用百分比最高的窗口。
    /// 只挡这几类：stale（失败旧值 / 数据陈旧）、incompatible、failed、无数据、过期窗口。
    /// 良性 warnings 不影响菜单栏出数（只在面板里显示）。
    /// 没有任何合格窗口时返回 nil（菜单栏只留图标）。
    public static func mostTense(in states: [ProviderState], now: Date = Date()) -> TensionWindow? {
        var best: TensionWindow?
        for state in states {
            if state.isMissingProbe || state.isIncompatibleSchema { continue }
            if state.isStale || state.isDataStale { continue }
            if state.status == .failed { continue }
            for window in state.windows {
                guard let used = window.usedPercent, used.isFinite else { continue }
                guard !window.isExpired(now: now) else { continue }
                let clamped = min(max(used, 0), 100)
                if let current = best, current.percent >= clamped { continue }
                best = TensionWindow(provider: state.provider, window: window, percent: clamped)
            }
        }
        return best
    }
}
