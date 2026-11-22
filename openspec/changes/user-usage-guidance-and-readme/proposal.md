# Change: 软件内使用提醒与 README 更新

## Why

用户不清楚 AGY 与 Gemini 标签页的用途，容易误以为必须寻找并粘贴 OAuth token。当前 Gemini 空态首先提示到配置提供账号，设置页自动复用说明不够突出；关于页仍写着「Codex / DeepSeek」。两个 README 仍描述 Python 运行时、仓库路径依赖及不完整的厂商列表，与当前实现不符。

## What Changes

- 在面板空态、配置页及现有帮助提示中提供简短、可执行的中文使用步骤：先登录对应工具，再选对应标签并刷新。
- AGY（Antigravity）使用 `agy acp --login`（或运行 `agy`）完成浏览器 Google 登录，自动复用 macOS 登录钥匙串，无需复制 token；Gemini（Gemini CLI / Code Assist）使用 `gemini` 完成浏览器 Google 登录，自动复用 `~/.gemini/oauth_creds.json`。手动 Gemini 配置明确为可选高级覆盖。
- 在配置页与 README 解释两者区别及旧配置缺少 AGY 时通过「添加模型厂商 → 添加 AGY」恢复的步骤。AGY 面板空态保持专属指导，绝不提及 Gemini。
- 补齐 Codex、OpenCode、DeepSeek 的简短使用提醒，更新关于页与两份 README 的支持范围、数据来源、隐私说明及原生 Swift 运行方式。
- 增补文案行为验证，保留既有诊断、跨主题/缩放渲染及认证隔离测试。

## Scope and Evidence

实现范围：`app/Sources/UsageLensUI/{PanelView,SettingsPanelView,AboutPanelView}.swift`、`app/Tests/UsageLensUITests/PanelRenderTests.swift`、`README.md`、`app/README.md`。

只读核对依据：`Provider.swift` 中可用厂商为 Codex、AGY、Gemini、OpenCode、DeepSeek，默认启用前四者；已保存的厂商列表不会自动补入 AGY。`ProbeRunner.swift` 调度原生 Swift 探针；`AgyNativeProbe.swift` 使用钥匙串 `service="gemini", account="antigravity"` 并统计本地今日 tokens；Gemini 设置已有手动覆盖及本机 CLI 来源两种状态。`build-app.sh` 目前仍复制 Python 脚本，但不代表 App 运行依赖 Python。

本变更仅改善说明及必要的 UI 展示，不改变探针、凭据发现/优先级/刷新、数据契约、厂商默认值、存储迁移、网络行为、构建脚本或依赖，不新增登录流程或自动打开终端。未知数据仍保持未知，不承诺登录后一定存在配额或本地记录。

## Delivery

任务均为常规任务，交由 tech_lead 审核后优先派发 coder_local；遵循项目规定的测试、独立审查及验收流程。本次 researcher 仅交付此 change 下三份规格文档，不执行实现、构建或修改状态总线。
