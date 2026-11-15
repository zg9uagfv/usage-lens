import SwiftUI

/// 明确可见的配置页；目前只放首版已确认的登录后启动开关。
public struct SettingsPanelView: View {
    @ObservedObject public var launchAtLogin: LaunchAtLoginManager

    public init(launchAtLogin: LaunchAtLoginManager) {
        self.launchAtLogin = launchAtLogin
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配置")
                .font(.system(size: 17, weight: .semibold))

            Toggle("登录后启动 UsageLens", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            Text("启用后，登录 macOS 时会自动启动菜单栏看板。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = launchAtLogin.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
    }
}
