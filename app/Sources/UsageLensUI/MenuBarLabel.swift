import SwiftUI
import UsageLensKit

/// 菜单栏常驻标签：取跨 provider 最紧张的窗口，例如 `Codex 5h 33%`。
/// 没有任何可用百分比时只留图标 —— 不编造数字。
public struct MenuBarLabel: View {
    @ObservedObject private var store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        if let tension = store.mostTense {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .medium))
                Text(tension.compactLabel)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .help("\(tension.fullLabel) · 点击查看全部 provider")
        } else {
            Image(systemName: "speedometer")
                .help("usage-lens · 暂无数据")
        }
    }
}
