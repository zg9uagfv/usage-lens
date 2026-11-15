import AppKit
import Combine
import SwiftUI
import UsageLensKit
import UsageLensUI

@main
struct UsageLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 状态栏和弹窗由 AppDelegate 创建。SwiftUI 的 MenuBarExtra 在某些 ad-hoc
        // bundle 上会运行但不现身；直接注册 NSStatusItem 更可靠。
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore(refreshInterval: UsageStore.environmentRefreshInterval)
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var stateSubscription: AnyCancellable?
    private var developmentPanel: NSPanel?
    private var settingsPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不占 Dock。
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 560)
        popover.contentViewController = NSHostingController(rootView: panelView)

        // 固定为紧凑图标。可变长度的「Codex 5h 45%」在菜单栏拥挤时会被系统挤出。
        let item = NSStatusBar.system.statusItem(withLength: 26)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.image = MenuBarIcon.make()
        statusItem = item

        stateSubscription = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在属性更新前发出，下一轮主队列再读取才能得到新标签。
            DispatchQueue.main.async { self?.updateStatusLabel() }
        }
        updateStatusLabel()

        // 仅用于验收：菜单栏被第三方工具隐藏时，可以显式打开普通窗口看面板。
        if ProcessInfo.processInfo.environment["USAGE_LENS_SHOW_PANEL"] == "1" {
            showDevelopmentPanel()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusLabel() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        if let tension = store.mostTense {
            button.toolTip = "\(tension.fullLabel) · 点击查看 UsageLens"
        } else {
            button.toolTip = "UsageLens · 暂无可用配额数据"
        }
    }

    private func showDevelopmentPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 368, height: 620),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "UsageLens"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: panelView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        developmentPanel = panel
    }

    private var panelView: PanelView {
        PanelView(store: store, launchAtLogin: launchAtLogin) { [weak self] in
            self?.showSettings()
        }
    }

    private func showSettings() {
        if let panel = settingsPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "UsageLens 配置"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: SettingsPanelView(launchAtLogin: launchAtLogin)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }
}
