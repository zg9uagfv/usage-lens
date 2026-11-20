import AppKit
import SwiftUI
import UsageLensKit

/// 「关于 usage-lens」：图标 + 名称 + 版本/构建号。
public struct AboutPanelView: View {
    @AppStorage("usageLens.theme") private var themeRawValue = UsageLensTheme.system.rawValue

    private var selectedTheme: UsageLensTheme {
        UsageLensTheme(rawValue: themeRawValue) ?? .system
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            Text("关于")
                .font(.system(size: 17, weight: .semibold))

            // 菜单栏同款「眼睛」图标，放大展示。
            MenuBarIconImage()
                .frame(width: 64, height: 54)

            VStack(spacing: 3) {
                Text("usage-lens")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(appVersion)（构建 \(buildNumber)）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text("菜单栏用量看板 · Codex / Gemini / DeepSeek")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 280, height: 230)
        .background(selectedTheme.panelBackground)
        .preferredColorScheme(selectedTheme.colorScheme)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

/// 菜单栏同款「眼睛」品牌图标：按当前主题 accent 重绘两只圆眼睛。
private struct MenuBarIconImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = Self.makeImage()
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = Self.makeImage()
    }

    private static func makeImage() -> NSImage {
        let theme = UsageLensTheme(rawValue: UserDefaults.standard.string(forKey: "usageLens.theme") ?? "") ?? .system
        let accent = NSColor(theme.accent)
        let image = NSImage(size: NSSize(width: 24, height: 20))
        image.lockFocus()
        accent.setStroke()
        accent.setFill()
        for centerX in [7.0, 17.0] {
            let eye = NSBezierPath(ovalIn: NSRect(x: centerX - 3.7, y: 5, width: 7.4, height: 10))
            eye.lineWidth = 1.7
            eye.stroke()
            NSBezierPath(ovalIn: NSRect(x: centerX - 1.1, y: 8.1, width: 2.2, height: 2.5)).fill()
        }
        image.unlockFocus()
        return image
    }
}
