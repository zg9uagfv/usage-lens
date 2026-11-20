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

    /// AppKit 外观名：NSPopover / NSWindow 的 appearance 不会跟随 SwiftUI 的
    /// preferredColorScheme，必须在这里显式同步，否则 .primary/.secondary 文字不反转。
    /// system 主题返回 nil，表示沿用系统外观。
    var appkitAppearanceName: NSAppearance.Name? {
        switch self {
        case .tech: .darkAqua
        case .anime: .aqua
        case .system: nil
        }
    }

    static var current: UsageLensTheme {
        UsageLensTheme(rawValue: UserDefaults.standard.string(forKey: "usageLens.theme") ?? "") ?? .system
    }

    /// 当前主题的 AppKit 外观；system 主题下返回系统有效外观。
    /// 非 AppKit 环境（单元测试）下 NSApp 为 nil，退回命名外观或空外观，避免崩溃。
    public static var appkitAppearance: NSAppearance {
        let system = NSApp?.effectiveAppearance ?? NSAppearance()
        if let name = current.appkitAppearanceName {
            return NSAppearance(named: name) ?? system
        }
        return system
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
            isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
        case .system: dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
    @Environment(\.displayScaleMetrics) private var metrics
    var corner: CGFloat = Theme.cardCorner
    var opacity: Double = 0.05

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: metrics.scaledSpacing(corner), style: .continuous)
                    .fill(UsageLensTheme.current.cardSurface)
            )
    }
}

extension View {
    func cardBackground(corner: CGFloat = Theme.cardCorner, opacity: Double = 0.05) -> some View {
        modifier(CardBackground(corner: corner, opacity: opacity))
    }
}

/// 主题变更计数器：PanelView 通过 @ObservedObject 观察它，
/// 切主题时 bump 一下即可让 SwiftUI 重跑 body（外部 NSView layout 做不到这点）。
@MainActor
public final class ThemeChangeSignal: ObservableObject {
    public static let shared = ThemeChangeSignal()
    @Published private(set) public var revision: Int = 0
    private init() {}
    public func bump() { revision += 1 }
}

/// 主题变化广播：NSPopover / NSWindow 里的 NSHostingView 缓存旧外观，光改
/// preferredColorScheme 不会驱动已创建的视图重渲。这里在 `usageLens.theme` 变动时
/// 切主题时同步 AppKit 外观并 bump 信号，让 PanelView 重建子树用新 colorScheme 重渲。
///
/// NSPopover/NSWindow 的 appearance 不跟随 SwiftUI 的 preferredColorScheme；
/// SwiftUI 对「外部已写入 UserDefaults」的 @AppStorage 变化也不一定即时重渲
/// 已创建的子树。这里在 theme 变动时：1) 同步 AppKit 外观 2) bump 信号触发
/// PanelView 的 .id 变化 → 整棵子树重建，保证文字/卡片颜色即时跟随。
@MainActor
public enum ThemeHostRegistrar {
    private static var observer: NSObjectProtocol?
    /// 上次见到的主题：与它比而非 current，避开 @AppStorage 抢先写入 current 的竞态。
    private static var lastSeenTheme: UsageLensTheme?

    /// 登记开始监听主题变化。幂等。
    public static func register(_ view: NSView) {
        lastSeenTheme = UsageLensTheme.current
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let raw = UserDefaults.standard.string(forKey: "usageLens.theme") ?? UsageLensTheme.system.rawValue
                let newTheme = UsageLensTheme(rawValue: raw) ?? .system
                defer { lastSeenTheme = newTheme }
                guard newTheme != lastSeenTheme else { return }
                reload()
            }
        }
    }

    private static func reload() {
        // 1) 只同步面板类窗口的 AppKit 外观。NSPopover / 开发面板不会跟随
        //    SwiftUI 的 preferredColorScheme；但菜单栏窗口（NSStatusBarWindow）
        //    必须保留系统外观，否则 template 图标颜色会被主题外观带偏。
        let appearance = UsageLensTheme.appkitAppearance
        for window in NSApp?.windows ?? [] where !isStatusBarWindow(window) {
            window.appearance = appearance
        }
        // 2) bump 信号 → PanelView 的 .id 变化 → SwiftUI 重建子树，用新 colorScheme 重渲文字/卡片。
        ThemeChangeSignal.shared.bump()
    }

    /// 菜单栏窗口（状态项所在窗口）：按类名或标识符识别，避免误改 template 图标外观。
    private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        if String(describing: type(of: window)).contains("StatusBarWindow") { return true }
        return window.identifier?.rawValue.contains("NSStatusBarWindow") == true
    }
}
