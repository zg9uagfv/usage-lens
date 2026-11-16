import SwiftUI
import UsageLensKit

/// 配置页：外观主题、自定义模型名称与登录后启动选项。
public struct SettingsPanelView: View {
    @ObservedObject public var launchAtLogin: LaunchAtLoginManager
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("usageLens.customModels") private var storedModels = ""
    @AppStorage("usageLens.theme") private var themeRawValue = UsageLensTheme.system.rawValue
    @State private var modelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var hasSavedAPIKey = DeepSeekAPIKeyStore.hasSavedKey
    @State private var apiKeyStatus: String?

    private let onAPIKeyChange: () -> Void

    public init(
        launchAtLogin: LaunchAtLoginManager,
        onAPIKeyChange: @escaping () -> Void = {}
    ) {
        self.launchAtLogin = launchAtLogin
        self.onAPIKeyChange = onAPIKeyChange
    }

    public var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("配置")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("外观主题")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(UsageLensTheme.allCases) { theme in
                    Button {
                        themeRawValue = theme.rawValue
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 13, height: 13)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.title).font(.system(size: 11, weight: .semibold))
                                Text(theme.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if theme.rawValue == themeRawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(theme.cardSurface))
                    }
                    .buttonStyle(.plain)
                    .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
                }
            }

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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("DeepSeek API Key")
                    .font(.system(size: 13, weight: .semibold))

                SecureField("粘贴 DeepSeek API Key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveAPIKey)

                HStack(spacing: 8) {
                    Button("保存到钥匙串", action: saveAPIKey)
                        .disabled(trimmedAPIKey.isEmpty)
                    if hasSavedAPIKey {
                        Button("删除", role: .destructive, action: deleteAPIKey)
                    }
                    Spacer(minLength: 0)
                }

                Text(hasSavedAPIKey ? "已安全保存在本机钥匙串。" : "尚未设置；本地花费估算仍可使用，余额查询需要 API Key。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let apiKeyStatus {
                    Text(apiKeyStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(apiKeyStatus.contains("失败") ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Text("自定义模型")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 6) {
                TextField("例如 gpt-5-codex", text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addModel)
                Button("添加", action: addModel)
                    .disabled(normalizedDraft.isEmpty || models.contains(normalizedDraft))
            }

            if models.isEmpty {
                Text("还没有自定义模型。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    ForEach(models, id: \.self) { model in
                        HStack {
                            Text(model)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                storedModels = models.filter { $0 != model }.joined(separator: "\n")
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除模型 \(model)")
                        }
                    }
                }
            }

            Text("模型名称保存在本机配置中。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
          }
          .padding(20)
        }
        .frame(width: 340, height: 480, alignment: .topLeading)
        .background(UsageLensTheme.current.panelBackground)
        .tint(UsageLensTheme.current.accent)
        .preferredColorScheme(UsageLensTheme.current.colorScheme)
    }

    private var models: [String] {
        storedModels.split(separator: "\n").map(String.init)
    }

    private var normalizedDraft: String {
        modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAPIKey() {
        do {
            try DeepSeekAPIKeyStore.save(trimmedAPIKey)
            hasSavedAPIKey = true
            apiKeyDraft = ""
            apiKeyStatus = "已保存，正在刷新 DeepSeek 数据…"
            onAPIKeyChange()
        } catch {
            apiKeyStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func deleteAPIKey() {
        do {
            try DeepSeekAPIKeyStore.delete()
            hasSavedAPIKey = false
            apiKeyDraft = ""
            apiKeyStatus = "已从钥匙串删除。"
            onAPIKeyChange()
        } catch {
            apiKeyStatus = "删除失败：\(error.localizedDescription)"
        }
    }

    private func addModel() {
        let model = normalizedDraft
        guard !model.isEmpty, !models.contains(model) else { return }
        storedModels = (models + [model]).joined(separator: "\n")
        modelDraft = ""
    }
}
