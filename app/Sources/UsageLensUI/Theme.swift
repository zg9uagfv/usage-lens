import AppKit
import SwiftUI
import UsageLensKit

enum Theme {
    static let panelWidth: CGFloat = 340
    static let cardCorner: CGFloat = 10
    static let barHeight: CGFloat = 6

    /// 进度与百分比配色：越紧张越暖，全部走系统色以跟随深浅色。
    static func tint(for percent: Double?) -> Color {
        guard let percent, percent.isFinite else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .accentColor
    }

    static func statusColor(_ status: ProviderStatus) -> Color {
        switch status {
        case .loading:
            return Color(nsColor: .tertiaryLabelColor)
        case .ok:
            return .green
        case .warning:
            return .yellow
        case .stale:
            return .orange
        case .failed:
            return .red
        case .empty, .missing:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// 卡片底：用 primary 的低透明度，深浅色自动反转。
struct CardBackground: ViewModifier {
    var corner: CGFloat = Theme.cardCorner
    var opacity: Double = 0.05

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(opacity))
            )
    }
}

extension View {
    func cardBackground(corner: CGFloat = Theme.cardCorner, opacity: Double = 0.05) -> some View {
        modifier(CardBackground(corner: corner, opacity: opacity))
    }
}
