import AppKit
import SwiftUI
import UsageLensKit

/// UI 的入口视图：provider tab + 当前 provider 详情 + 底部刷新。
public struct PanelView: View {
    @ObservedObject private var store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            ProviderTabBar(store: store)
            Divider().opacity(0.35)
            ProviderDetailView(state: store.state(for: store.selected))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
            Divider().opacity(0.35)
            FooterBar(store: store)
        }
        .frame(width: Theme.panelWidth)
    }
}

// MARK: - Tab 头

struct ProviderTabBar: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ProviderCatalog.all) { provider in
                let isSelected = store.selected == provider
                Button {
                    store.selected = provider
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.statusColor(store.state(for: provider).status))
                            .frame(width: 6, height: 6)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(provider.displayName) 用量")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

// MARK: - 详情

struct ProviderDetailView: View {
    let state: ProviderState

    private var isDimmed: Bool { state.isStale }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !state.hasLoaded {
                loadingRow
            } else if !state.windows.isEmpty {
                windowsSection
                    .saturation(isDimmed ? 0.2 : 1)
                    .opacity(isDimmed ? 0.55 : 1)
            } else if hasMetrics {
                noWindowCaption
            } else {
                emptyTile
            }

            if hasMetrics {
                metricsRow
                    .saturation(isDimmed ? 0.4 : 1)
                    .opacity(isDimmed ? 0.7 : 1)
            }

            if state.isStale, let failure = state.failureReason {
                staleBanner(failure)
            }

            if !state.warnings.isEmpty {
                warningsList
            }
        }
    }

    private var hasMetrics: Bool {
        state.envelope?.balance != nil || state.envelope?.spend != nil
    }

    // 账号 + plan
    private var header: some View {
        HStack(spacing: 6) {
            Text(state.accountLabel ?? "未提供账号")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(state.accountLabel == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let plan = UsageFormat.planLabel(state.planLabel) {
                Text(plan)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer(minLength: 0)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("读取探针…").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    private var windowsSection: some View {
        VStack(spacing: 8) {
            ForEach(state.windows) { window in
                WindowRowView(window: window)
            }
        }
    }

    // 没有窗口概念的服务（例如 DeepSeek）：不画进度条，只说明。
    private var noWindowCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "minus.circle").font(.system(size: 10))
            Text("该服务无窗口配额").font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private var emptyTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("无数据")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let reason = emptyReason {
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .cardBackground(opacity: 0.04)
    }

    private var emptyReason: String? {
        if state.isMissingProbe {
            return "未安装探针 \(state.provider.probeRelativePath)"
        }
        if let failure = state.failureReason {
            return failure
        }
        guard state.hasLoaded else { return "正在读取探针" }
        return "探针没有返回窗口数据"
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            if let balance = state.envelope?.balance {
                MetricTile(
                    title: "余额",
                    value: UsageFormat.money(balance.amount, currency: balance.currency) ?? "未知",
                    note: UsageFormat.sourceLabel(balance.source)
                )
            } else if state.envelope != nil {
                MetricTile(title: "余额", value: "未知", note: "未获取")
            }

            if let spend = state.envelope?.spend {
                if spend.today != nil {
                    MetricTile(
                        title: "今日花费",
                        value: UsageFormat.money(spend.today, currency: spend.currency) ?? "未知",
                        note: UsageFormat.sourceLabel(spend.source)
                    )
                }
                if spend.window != nil {
                    MetricTile(
                        title: "窗口花费",
                        value: UsageFormat.money(spend.window, currency: spend.currency) ?? "未知",
                        note: UsageFormat.sourceLabel(spend.source)
                    )
                }
            }
        }
    }

    private func staleBanner(_ failure: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(staleTitle)
                    .font(.system(size: 11, weight: .medium))
                Text(failure)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var staleTitle: String {
        guard let date = state.lastDataAt else { return "探针失败，显示上次成功值" }
        let phrase = UsageFormat.updatedText(at: date).replacingOccurrences(of: "更新", with: "")
        return "探针失败，显示\(phrase)的上次成功值"
    }

    private var warningsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.top, 1.5)
                    Text(warning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - 单个窗口

struct WindowRowView: View {
    let window: ProbeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label ?? window.id)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(UsageFormat.usedText(window.usedPercent))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent == nil ? Color.secondary : Theme.tint(for: window.usedPercent))
            }

            ProgressTrack(
                fraction: UsageFormat.fraction(window.usedPercent),
                tint: Theme.tint(for: window.usedPercent)
            )

            HStack(spacing: 6) {
                if let reset = UsageFormat.resetCountdown(until: window.resetsAt) {
                    Text(reset)
                        .foregroundStyle(UsageFormat.isExpired(resetAt: window.resetsAt) ? Color.orange : Color.secondary)
                } else {
                    Text("重置时间未知").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let basis = UsageFormat.basisLabel(window.basis) {
                    Text(basis).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

struct ProgressTrack: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                if let fraction {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.72), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(proxy.size.width * fraction, 4))
                } else {
                    Capsule()
                        .strokeBorder(
                            Color.primary.opacity(0.18),
                            style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])
                        )
                }
            }
        }
        .frame(height: Theme.barHeight)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .cardBackground(corner: 9)
    }
}

// MARK: - 底部

struct FooterBar: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 10) {
            refreshButton
            Spacer(minLength: 0)
            Text(UsageFormat.updatedText(at: store.state(for: store.selected).lastDataAt))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            quitButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var refreshButton: some View {
        Button {
            store.refresh()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
                Text(store.isRefreshing ? "刷新中" : "刷新")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isRefreshing)
        .help("立即重新运行探针")
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("退出 usage-lens")
    }
}
