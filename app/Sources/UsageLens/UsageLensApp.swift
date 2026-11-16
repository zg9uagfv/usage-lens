import AppKit
import Combine
import QuartzCore
import SwiftUI
import UsageLensKit
import UsageLensUI

@main
struct UsageLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 状态栏和弹窗由 AppDelegate 创建。SwiftUI 的 MenuBarExtra 在某些 ad-hoc
        // bundle 上会运行但不现身；直接注册 NSStatusItem 更可靠。
        // 配置由 AppDelegate 的自定义 NSWindow 承载，禁用 SwiftUI 自动附带的
        // 「usage-lens 设置」窗口，避免关闭配置时又弹出一个空的大窗口。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore(refreshInterval: UsageStore.environmentRefreshInterval)
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var stateSubscription: AnyCancellable?
    private var blinkTimer: Timer?
    private var openEyesTimer: Timer?
    private var isCriticalUsage = false
    private var developmentPanel: NSPanel?
    private var settingsPanel: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不占 Dock。
        NSApp.setActivationPolicy(.accessory)
        closeRestoredSwiftUISettingsWindow()
        // SwiftUI 的 Settings scene 可能在 didFinish 后才被窗口恢复机制创建。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.closeRestoredSwiftUISettingsWindow()
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 560)
        popover.contentViewController = NSHostingController(rootView: panelView)

        let item = NSStatusBar.system.statusItem(withLength: 32)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.wantsLayer = true
        updateIcon()
        statusItem = item
        blinkTimer = Timer.scheduledTimer(timeInterval: 3.2, target: self, selector: #selector(blink), userInfo: nil, repeats: true)

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

    func applicationWillTerminate(_ notification: Notification) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        openEyesTimer?.invalidate()
        openEyesTimer = nil
        statusItem?.button?.layer?.removeAnimation(forKey: "usageLens.criticalPulse")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        closeRestoredSwiftUISettingsWindow()
    }

    @objc private func blink() {
        updateIcon(blinking: true)
        openEyesTimer?.invalidate()
        openEyesTimer = Timer.scheduledTimer(timeInterval: 0.16, target: self, selector: #selector(openEyes), userInfo: nil, repeats: false)
    }

    @objc private func openEyes() {
        updateIcon()
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
        let shouldAlert = store.hasCriticalUsage
        if isCriticalUsage != shouldAlert {
            isCriticalUsage = shouldAlert
            updateIcon()
            updateCriticalPulse()
        }
        button.toolTip = shouldAlert ? "usage-lens：用量已达 90%" : "usage-lens"
    }

    private func updateIcon(blinking: Bool = false) {
        statusItem?.button?.image = MenuBarIcon.make(blinking: blinking, alert: isCriticalUsage)
    }

    private func updateCriticalPulse() {
        guard let layer = statusItem?.button?.layer else { return }
        layer.removeAnimation(forKey: "usageLens.criticalPulse")
        guard isCriticalUsage, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 0.84
        pulse.duration = 0.62
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "usageLens.criticalPulse")
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
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "UsageLens 配置"
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.contentViewController = NSHostingController(
            rootView: SettingsPanelView(launchAtLogin: launchAtLogin) { [weak self] in
                self?.store.refresh()
            }
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }

    private func closeRestoredSwiftUISettingsWindow() {
        for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
            window.isRestorable = false
            window.orderOut(nil)
            window.close()
        }
    }
}
