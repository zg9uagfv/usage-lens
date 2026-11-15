import Foundation
import ServiceManagement

/// 使用系统的登录项服务管理开机自启；不写 LaunchAgent，也不保存额外凭据或配置。
@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var errorMessage: String?

    public init() {
        isEnabled = SMAppService.mainApp.status == .enabled
        errorMessage = nil
    }

    public func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = isEnabled ? nil : "系统没有启用登录后启动"
        } catch {
            errorMessage = "无法更新登录后启动：\(error.localizedDescription)"
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
