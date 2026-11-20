import SwiftUI
import UsageLensKit

/// 配置页：外观主题、模型厂商与登录后启动选项。
public struct SettingsPanelView: View {
    @ObservedObject public var launchAtLogin: LaunchAtLoginManager
    @Environment(\.displayScaleMetrics) private var metrics
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("usageLens.providers") private var storedProviderIDs = ProviderCatalog.defaultActiveIDs.joined(separator: ",")
    @AppStorage("usageLens.theme") private var themeRawValue = UsageLensTheme.system.rawValue
    @State private var expandedKeyProviderID: String?
    @State private var apiKeyDraft = ""
    @State private var hasSavedAPIKey: Bool
    @State private var apiKeyStatus: String?
    @State private var isVerifyingAPIKey = false

    private let onAPIKeyChange: () -> Void

    public init(
        launchAtLogin: LaunchAtLoginManager,
        hasSavedAPIKey: Bool? = nil,
        onAPIKeyChange: @escaping () -> Void = {}
    ) {
        self.launchAtLogin = launchAtLogin
        _hasSavedAPIKey = State(initialValue: hasSavedAPIKey ?? DeepSeekAPIKeyStore.hasSavedKey)
        self.onAPIKeyChange = onAPIKeyChange
    }

    public var body: some View {
        let dotSize = metrics.scaledDimension(13, minimum: 10)
        ScrollView {
          VStack(alignment: .leading, spacing: metrics.scaledSpacing(16)) {
            Text("配置")
                .font(metrics.font(17, weight: .semibold))

            VStack(alignment: .leading, spacing: metrics.scaledSpacing(8)) {
                Text("外观主题")
                    .font(metrics.font(13, weight: .semibold))
                ForEach(UsageLensTheme.allCases) { theme in
                    Button {
                        themeRawValue = theme.rawValue
                    } label: {
                        HStack(spacing: metrics.scaledSpacing(9)) {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: dotSize, height: dotSize)
                            VStack(alignment: .leading, spacing: metrics.scaledSpacing(2)) {
                                Text(theme.title).font(metrics.font(11, weight: .semibold))
                                Text(theme.subtitle).font(metrics.font(9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if theme.rawValue == themeRawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(metrics.font(13))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .padding(metrics.scaledSpacing(8))
                        .background(RoundedRectangle(cornerRadius: metrics.scaledSpacing(9)).fill(theme.cardSurface))
                    }
                    .buttonStyle(.plain)
                    .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
                }
            }

            Toggle("登录后启动 UsageLens", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .font(metrics.font(13))
            .toggleStyle(.switch)

            Text("启用后，登录 macOS 时会自动启动菜单栏看板。")
                .font(metrics.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = launchAtLogin.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(metrics.font(11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("模型厂商")
                .font(metrics.font(13, weight: .semibold))

            VStack(spacing: metrics.scaledSpacing(5)) {
                ForEach(activeProviders) { provider in
                    HStack(spacing: metrics.scaledSpacing(8)) {
                        Button {
                            if provider.id == ProviderCatalog.deepseek.id {
                                expandedKeyProviderID = expandedKeyProviderID == provider.id ? nil : provider.id
                                apiKeyStatus = nil
                            }
                        } label: {
                            HStack(spacing: metrics.scaledSpacing(8)) {
                                Image(systemName: "building.2.crop.circle")
                                    .font(metrics.font(13))
                                    .foregroundStyle(UsageLensTheme.current.accent)
                                Text(provider.displayName)
                                    .font(metrics.font(11, weight: .medium))
                                if provider.requiresAPIKey {
                                    Image(systemName: "key.fill")
                                        .font(metrics.font(10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: metrics.scaledSpacing(4))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!provider.requiresAPIKey)
                        .accessibilityLabel(provider.requiresAPIKey ? "配置 \(provider.displayName) API Key" : provider.displayName)
                        if provider.id != ProviderCatalog.codex.id {
                            Button(role: .destructive) {
                                setProviderEnabled(provider, enabled: false)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(metrics.font(13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除模型厂商 \(provider.displayName)")
                        }
                    }
                    .padding(.vertical, metrics.scaledSpacing(3))
                }
            }

            Menu {
                ForEach(addableProviders) { provider in
                    Button("添加 \(provider.displayName)") {
                        setProviderEnabled(provider, enabled: true)
                    }
                }
            } label: {
                Label("添加模型厂商", systemImage: "plus.circle")
                    .font(metrics.font(11, weight: .medium))
            }
            .disabled(addableProviders.isEmpty)

            Text("管理要显示的模型厂商。模型用量来自各厂商的本地记录或探针。")
                .font(metrics.font(10))
                .foregroundStyle(.tertiary)

            if let provider = activeProviders.first(where: { $0.id == expandedKeyProviderID && $0.requiresAPIKey }) {
                Divider()
                apiKeySettings(for: provider)
            }
          }
          .padding(metrics.scaledSpacing(20))
        }
        .frame(
            width: metrics.settingsContentSize.width,
            height: metrics.settingsContentSize.height,
            alignment: .topLeading
        )
        .background(UsageLensTheme.current.panelBackground)
        .tint(UsageLensTheme.current.accent)
        .preferredColorScheme(UsageLensTheme.current.colorScheme)
    }

    private var activeProviders: [Provider] {
        let ids = Set(storedProviderIDs.split(separator: ",").map(String.init))
        let providers = ProviderCatalog.available.filter { ids.contains($0.id) }
        return providers.isEmpty ? [ProviderCatalog.codex] : providers
    }

    private var addableProviders: [Provider] {
        let activeIDs = Set(activeProviders.map(\.id))
        return ProviderCatalog.available.filter { !activeIDs.contains($0.id) }
    }

    private func setProviderEnabled(_ provider: Provider, enabled: Bool) {
        var ids = activeProviders.map(\.id)
        if enabled, !ids.contains(provider.id) {
            ids.append(provider.id)
        } else if !enabled, provider.id != ProviderCatalog.codex.id {
            ids.removeAll { $0 == provider.id }
        }
        storedProviderIDs = ids.joined(separator: ",")
        if !enabled, expandedKeyProviderID == provider.id {
            expandedKeyProviderID = nil
        }
    }

    private var trimmedAPIKey: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func apiKeySettings(for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaledSpacing(8)) {
            Text("\(provider.displayName) API Key")
                .font(metrics.font(13, weight: .semibold))

            if hasSavedAPIKey {
                // 从钥匙串读取的密钥永不回填到 UI；只表明已有密钥并允许删除。
                TextField("", text: .constant("****************"))
                    .font(metrics.font(12))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .accessibilityLabel("已保存的 \(provider.displayName) API Key")

                HStack(spacing: metrics.scaledSpacing(8)) {
                    Button("删除", role: .destructive, action: deleteAPIKey)
                        .font(metrics.font(12))
                    Spacer(minLength: 0)
                }
                Text("已保存的密钥以掩码显示，不会读取或显示明文。")
                    .font(metrics.font(10))
                    .foregroundStyle(.secondary)
            } else {
                SecureField(
                    "粘贴 \(provider.displayName) API Key",
                    text: $apiKeyDraft
                )
                .font(metrics.font(12))
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAPIKey)

                HStack(spacing: metrics.scaledSpacing(8)) {
                    Button(isVerifyingAPIKey ? "正在验证…" : "验证并保存", action: saveAPIKey)
                        .font(metrics.font(12))
                        .disabled(trimmedAPIKey.isEmpty || isVerifyingAPIKey)
                    Spacer(minLength: 0)
                }
                Text("密钥输入全程以 ✳ 掩码显示；仅验证成功后才会写入本机钥匙串。")
                    .font(metrics.font(10))
                    .foregroundStyle(.secondary)
            }
            if let apiKeyStatus {
                Text(apiKeyStatus)
                    .font(metrics.font(10))
                    .foregroundStyle(apiKeyStatus.contains("失败") ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveAPIKey() {
        let candidate = trimmedAPIKey
        guard !candidate.isEmpty, !isVerifyingAPIKey else { return }
        isVerifyingAPIKey = true
        apiKeyStatus = nil
        Task { @MainActor in
            if let message = await DeepSeekAPIKeyStore.validationMessage(for: candidate) {
                isVerifyingAPIKey = false
                apiKeyStatus = "验证失败：\(message)"
                return
            }
            do {
                try DeepSeekAPIKeyStore.save(candidate)
                hasSavedAPIKey = true
                apiKeyDraft = ""
                expandedKeyProviderID = nil
                apiKeyStatus = nil
                onAPIKeyChange()
            } catch {
                apiKeyStatus = "保存失败：\(error.localizedDescription)"
            }
            isVerifyingAPIKey = false
        }
    }

    private func deleteAPIKey() {
        do {
            try DeepSeekAPIKeyStore.delete()
            hasSavedAPIKey = false
            apiKeyDraft = ""
            expandedKeyProviderID = ProviderCatalog.deepseek.id
            apiKeyStatus = "已从钥匙串删除。"
            onAPIKeyChange()
        } catch {
            apiKeyStatus = "删除失败：\(error.localizedDescription)"
        }
    }

}
