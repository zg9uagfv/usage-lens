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
    private var aboutPanel: NSWindow?
    private let popoverScaleController = DisplayScaleController()
    private let developmentScaleController = DisplayScaleController()
    private let settingsScaleController = DisplayScaleController()
    private let aboutScaleController = DisplayScaleController()
    private var screenParametersObserver: NSObjectProtocol?
    private var windowScreenObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不占 Dock。
        NSApp.setActivationPolicy(.accessory)
        closeRestoredSwiftUISettingsWindow()
        // SwiftUI 的 Settings scene 可能在 didFinish 后才被窗口恢复机制创建。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.closeRestoredSwiftUISettingsWindow()
        }

        let initialMetrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
        popoverScaleController.update(initialMetrics)
        popover.behavior = .transient
        popover.contentSize = initialMetrics.popoverSize
        // rootView 用 AnyView 包一层：切主题时可原地替换 rootView 强制重渲，
        // 避免 NSHostingView 缓存旧外观导致文字颜色不跟随。
        popover.contentViewController = NSHostingController<AnyView>(rootView: AnyView(scaledPopoverView))
        popover.appearance = UsageLensTheme.appkitAppearance

        let item = NSStatusBar.system.statusItem(withLength: 32)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.wantsLayer = true
        updateIcon()
        statusItem = item
        blinkTimer = Timer.scheduledTimer(timeInterval: 3.2, target: self, selector: #selector(blink), userInfo: nil, repeats: true)

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersDidChange()
            }
        }

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
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        for observer in windowScreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowScreenObservers.removeAll()
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
            let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
            popoverScaleController.update(metrics)
            popover.contentSize = metrics.popoverSize

            // 切主题后 NSPopover / NSHostingView 缓存的旧外观不会自动失效，
            // 必须在每次打开前：同步 appearance + 重建 rootView 强制 SwiftUI 用新外观重渲。
            let appearance = UsageLensTheme.appkitAppearance
            popover.appearance = appearance
            if let host = popover.contentViewController as? NSHostingController<AnyView> {
                host.rootView = AnyView(scaledPopoverView)
            }
            popover.contentViewController?.view.appearance = appearance
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
        let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
        developmentScaleController.update(metrics)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: metrics.developmentPanelSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "UsageLens"
        panel.isReleasedWhenClosed = false
        panel.appearance = UsageLensTheme.appkitAppearance
        panel.contentViewController = NSHostingController(
            rootView: ScaledHostingView(controller: developmentScaleController) { [self] in
                panelView
            }
        )
        observeScreenChange(
            for: panel,
            controller: developmentScaleController,
            sizeFor: \.developmentPanelSize
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        developmentPanel = panel
    }

    private var scaledPopoverView: some View {
        ScaledHostingView(controller: popoverScaleController) { [self] in
            panelView
        }
    }

    private var panelView: PanelView {
        PanelView(store: store, launchAtLogin: launchAtLogin) { [weak self] in
            self?.showSettings()
        } showAbout: { [weak self] in
            self?.showAbout()
        }
    }

    private func showAbout() {
        if let panel = aboutPanel {
            panel.appearance = UsageLensTheme.appkitAppearance
            refreshWindowScale(panel, controller: aboutScaleController, sizeFor: \.aboutWindowSize)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
        aboutScaleController.update(metrics)
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: metrics.aboutWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "关于 usage-lens"
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.appearance = UsageLensTheme.appkitAppearance
        panel.contentViewController = NSHostingController(
            rootView: ScaledHostingView(controller: aboutScaleController) {
                AboutPanelView()
            }
        )
        observeScreenChange(
            for: panel,
            controller: aboutScaleController,
            sizeFor: \.aboutWindowSize
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutPanel = panel
    }

    private func showSettings() {
        if let panel = settingsPanel {
            panel.appearance = UsageLensTheme.appkitAppearance
            refreshWindowScale(panel, controller: settingsScaleController, sizeFor: \.settingsWindowSize)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
        settingsScaleController.update(metrics)
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: metrics.settingsWindowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "UsageLens 配置"
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.appearance = UsageLensTheme.appkitAppearance
        panel.contentViewController = NSHostingController(
            rootView: ScaledHostingView(controller: settingsScaleController) { [weak self, launchAtLogin] in
                SettingsPanelView(launchAtLogin: launchAtLogin) {
                    self?.store.refresh()
                }
            }
        )
        observeScreenChange(
            for: panel,
            controller: settingsScaleController,
            sizeFor: \.settingsWindowSize
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }

    private func activeStatusScreen() -> NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func observeScreenChange(
        for window: NSWindow,
        controller: DisplayScaleController,
        sizeFor: @escaping (DisplayScaleMetrics) -> CGSize
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.refreshWindowScale(window, controller: controller, sizeFor: sizeFor)
            }
        }
        windowScreenObservers.append(observer)
    }

    private func handleScreenParametersDidChange() {
        if popover.isShown {
            let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())
            popoverScaleController.update(metrics)
            popover.contentSize = metrics.popoverSize
        }
        if let panel = settingsPanel {
            refreshWindowScale(panel, controller: settingsScaleController, sizeFor: \.settingsWindowSize)
        }
        if let panel = aboutPanel {
            refreshWindowScale(panel, controller: aboutScaleController, sizeFor: \.aboutWindowSize)
        }
        if let panel = developmentPanel {
            refreshWindowScale(panel, controller: developmentScaleController, sizeFor: \.developmentPanelSize)
        }
    }

    private func refreshWindowScale(
        _ window: NSWindow,
        controller: DisplayScaleController,
        sizeFor: (DisplayScaleMetrics) -> CGSize
    ) {
        let targetScreen = window.screen ?? activeStatusScreen()
        let metrics = DisplayScaleMetrics.from(screen: targetScreen)
        controller.update(metrics)
        resizeWindowPreservingCenter(window, to: sizeFor(metrics), on: targetScreen)
    }

    private func resizeWindowPreservingCenter(_ window: NSWindow, to contentSize: NSSize, on screen: NSScreen?) {
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let visibleFrame = (screen ?? window.screen ?? activeStatusScreen())?.visibleFrame
        let targetFrame = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: window.frame,
            targetFrameSize: targetFrameSize,
            in: visibleFrame
        )
        let old = window.frame
        guard abs(old.origin.x - targetFrame.origin.x) >= 1
            || abs(old.origin.y - targetFrame.origin.y) >= 1
            || abs(old.size.width - targetFrame.size.width) >= 1
            || abs(old.size.height - targetFrame.size.height) >= 1 else {
            return
        }
        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func closeRestoredSwiftUISettingsWindow() {
        for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
            window.isRestorable = false
            window.orderOut(nil)
            window.close()
        }
    }
}
