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

    /// 用量状态色使用明确的浅/深色变体，避免系统色在不同主题里变淡。
    static func tint(for percent: Double?) -> Color {
        guard let percent, percent.isFinite else { return .secondary }
        let isDark: Bool
        switch UsageLensTheme.current {
        case .tech: isDark = true
        case .anime: isDark = false
        case .system:
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        if percent >= 90 {
            return isDark ? Color(red: 1.0, green: 0.36, blue: 0.34) : Color(red: 0.78, green: 0.12, blue: 0.16)
        }
        if percent >= 70 {
            return isDark ? Color(red: 1.0, green: 0.66, blue: 0.24) : Color(red: 0.78, green: 0.36, blue: 0.04)
        }
        switch UsageLensTheme.current {
        case .tech: return Color(red: 0.27, green: 0.91, blue: 1.0)
        case .anime: return Color(red: 0.68, green: 0.20, blue: 0.62)
        case .system: return isDark ? Color(red: 0.36, green: 0.82, blue: 1.0) : Color(red: 0.08, green: 0.36, blue: 0.78)
        }
    }

    static var progressTrack: Color {
        let dark: Bool
        switch UsageLensTheme.current {
        case .tech: dark = true
        case .anime: dark = false
        case .system: dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return dark ? Color.white.opacity(0.22) : Color.black.opacity(0.15)
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
