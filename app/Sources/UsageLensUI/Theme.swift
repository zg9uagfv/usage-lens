import AppKit
import SwiftUI
import UsageLensKit

public enum UsageLensTheme: String, CaseIterable, Identifiable {
    case tech = "tech"
    case anime = "anime"
    case system = "system"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .tech: "科技感"
        case .anime: "二次元"
        case .system: "跟随系统"
        }
    }

    var subtitle: String {
        switch self {
        case .tech: "深空底色 · 霓虹青蓝"
        case .anime: "梦幻粉紫 · 柔和彩色点缀"
        case .system: "自动适配 macOS 明暗外观"
        }
    }

    var accent: Color {
        switch self {
        case .tech: Color(red: 0.20, green: 0.82, blue: 0.96)
        case .anime: Color(red: 0.83, green: 0.35, blue: 0.72)
        case .system: Color.accentColor
        }
    }

    var panelBackground: Color {
        switch self {
        case .tech: Color(red: 0.035, green: 0.065, blue: 0.11)
        case .anime: Color(red: 0.99, green: 0.94, blue: 0.98)
        case .system: Color(nsColor: .windowBackgroundColor)
        }
    }

    var cardSurface: Color {
        switch self {
        case .tech: Color(red: 0.065, green: 0.12, blue: 0.19)
        case .anime: Color(red: 1.0, green: 0.985, blue: 1.0)
        case .system: Color.primary.opacity(0.045)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .tech: .dark
        case .anime: .light
        case .system: nil
        }
    }

    static var current: UsageLensTheme {
        UsageLensTheme(rawValue: UserDefaults.standard.string(forKey: "usageLens.theme") ?? "") ?? .system
    }
}

enum Theme {
    static let panelWidth: CGFloat = 340
    static let cardCorner: CGFloat = 10
    static let barHeight: CGFloat = 6

    /// 进度与百分比配色：越紧张越暖，全部走系统色以跟随深浅色。
    static func tint(for percent: Double?) -> Color {
        guard let percent, percent.isFinite else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return UsageLensTheme.current.accent
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
        case .failed, .incompatible:
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
                    .fill(UsageLensTheme.current.cardSurface)
            )
    }
}

extension View {
    func cardBackground(corner: CGFloat = Theme.cardCorner, opacity: Double = 0.05) -> some View {
        modifier(CardBackground(corner: corner, opacity: opacity))
    }
}
