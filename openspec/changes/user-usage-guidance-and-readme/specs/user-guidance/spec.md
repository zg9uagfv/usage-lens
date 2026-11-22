# Capability: user-guidance

## ADDED Requirements

### Requirement: 软件内给出可执行的首次使用路径

界面 MUST 以简短中文说明「终端登录对应工具 → 选择对应标签 → 刷新」，配置页提供各厂商提示，面板空态给出当前厂商的下一步。提示 MUST 可换行，在既有窗口、三种主题及现有显示缩放档位下可读；较长的设置说明可通过现有滚动区域访问。现有页脚刷新、齿轮配置及帮助提示 MUST 让用户识别刷新和配置入口，不引入新登录机制。

#### Scenario: AGY 缺少或无法使用登录态
- **WHEN** 用户选择 AGY，出现缺失、拒绝钥匙串访问、隔离环境或过期等既有认证诊断
- **THEN** 空态保留具体原因及「重新检测 AGY」操作，补充适用步骤：终端运行 `agy acp --login`（或 `agy`），通过浏览器 Google 登录，再返回重新检测；钥匙串拒绝时保留解锁/允许访问指导，不以通用登录提示覆盖诊断
- **AND** 说明自动复用本机 AGY 登录态、无需手动复制 OAuth token
- **AND** AGY 空态全部可见文案（含新增帮助文字）不出现 `Gemini`、不引导到 Gemini 配置、不使用无效命令 `agy login`；钥匙串内部 service 名仅可在 README 技术说明中出现
- **AND** 有本地今日 tokens 但无实时配额的状态保留已有数据及诊断，不伪造配额或强制变成全空态

#### Scenario: Gemini 首次使用与可选手动覆盖
- **WHEN** Gemini 未配置，或用户打开 Gemini 账号设置
- **THEN** 优先显示终端运行 `gemini`、选择浏览器 Google 登录、返回刷新，并解释自动复用 `~/.gemini/oauth_creds.json`，通常无需手动 token
- **AND** Gemini 空态可提醒实际使用 Antigravity 的用户选择 AGY；缺少标签时到「配置 → 添加模型厂商 → 添加 AGY」
- **AND** 邮箱 + OAuth access token + 可选 Google Cloud Project ID 表单保留，明确标注为可选高级覆盖、手动保存优先于本机 CLI 登录；不把 API Key 当作此表单的 OAuth token
- **AND** 已有手动保存、CLI 自动复用、未配置三种状态仍准确展示；验证成功才保存、掩码与删除行为保持不变

### Requirement: 配置与关于页准确解释支持范围

#### Scenario: 选择厂商及升级恢复标签
- **WHEN** 用户查看配置页
- **THEN** 能理解 AGY = Antigravity，Gemini = Gemini CLI / Code Assist；两者自动复用各自登录态，不要求给 AGY 填写 Gemini 凭据
- **AND** 明确提示旧版已保存列表可能没有 AGY，使用「添加模型厂商 → 添加 AGY」后切回面板选择 AGY；不要求删除偏好或重装，也不修改既有启用列表
- **AND** Codex 提示先在终端运行 `codex` 登录并使用以生成本地记录；OpenCode 如实说明当前为预留标签、原生用量探针尚未接入，无需在 UsageLens 填 token，可在配置中按需移除
- **AND** DeepSeek 提示余额需在配置中验证并保存 API Key、本地花费为估算，缺少记录不保证有数值

#### Scenario: 关于页展示产品范围
- **WHEN** 用户打开关于页
- **THEN** 描述覆盖当前五个厂商，或使用准确的多厂商概述，不再写成仅支持 Codex / DeepSeek；原有版本号与构建号保留且布局可读

### Requirement: 两份 README 与原生实现一致

#### Scenario: 从 README 完成首次使用
- **WHEN** 用户阅读根目录 README
- **THEN** 有清晰的「如何使用」「各厂商登录方式」「AGY 与 Gemini 区别」「升级后找不到 AGY 标签页怎么办」内容，可合并相邻章节但不能遗漏步骤
- **AND** 有五厂商表，列出登录/凭据方式和真实数据口径：Codex 实时配额与本地日志回退、今日 tokens；AGY 实时窗口与本地今日 tokens；Gemini 账号配额窗口；OpenCode 当前为预留标签（原生用量探针尚未接入，无需填 token，可按需移除）；DeepSeek 官方余额与本地花费估算
- **AND** AGY 登录步骤、钥匙串自动读取（`service="gemini", account="antigravity"`）、Gemini CLI 凭据路径、零手动 token 的首选路径及可选高级覆盖与 UI 一致
- **AND** 说明默认启用 Codex / AGY / Gemini / OpenCode，DeepSeek 按需添加；旧保存列表通过设置补加 AGY，不声称自动迁移

#### Scenario: 构建、运行及隐私说明准确
- **WHEN** 用户按任一 README 构建或将生成的 App 移出仓库
- **THEN** 构建/启动命令路径正确，说明 App 当前使用原生 Swift 探针，日常运行无需 Python、`probes/` 或 `USAGE_LENS_ROOT`；保留 Python 文件的兼容/测试用途说明时，不将其描述为当前运行时
- **AND** `app/README.md` 提供精简使用步骤并以有效相对链接指向根 README 完整指南，开发环境变量只按当前代码实际用途描述
- **AND** 不再出现「仅 Codex 与 DeepSeek」或「密钥仅注入 Python 探针进程」等过时描述；隐私说明区分本地日志读取与向对应官方服务发起认证/配额/余额请求，不宣称完全离线或所有凭据只读（AGY 可刷新并回写登录态）
- **AND** 不提供导出、查找、粘贴真实 token 的教程或真实凭据示例；缺失数据、过期及估算值的说明不作成功保证

### Requirement: 回归验证覆盖文案与实际渲染

#### Scenario: 交付验收
- **WHEN** 完成文案实现
- **THEN** 保留并通过 `testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance` 及全部既有测试；新增断言检查实际 UI 文案而非仅检查探针 warnings，覆盖登录命令、AGY 空态禁词、Gemini 自动复用/高级覆盖及升级指引
- **AND** 使用假数据/现有 fixtures 验证，不依赖真实账号或网络；检查三主题及既有显示档位下新增提示、滚动内容与关于页可读
- **AND** 从仓库根执行 `swift test --package-path app` 与 `app/Scripts/build-app.sh`，记录退出码、测试结果和产物路径；实际启动打包 App 检查入口、标签、配置和帮助，不以构建成功替代运行验收
