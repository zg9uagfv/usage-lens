# Tasks: user-usage-guidance-and-readme

本变更全部为常规任务，无复杂模块。由 tech_lead 审核规格并优先派发 coder_local；仅按 AGENTS.md 的合法例外及证据登记规则替代。本 researcher 不修改实现或 `.orca-relay/*`。下列事项待实现，不代表已有测试通过。

- [x] 1. **常规任务**：更新 `PanelView.swift` 的 Gemini 首次使用、AGY 专属提醒及现有页脚/帮助提示。
  - 验收：Gemini 先显示 `gemini` 浏览器 Google 登录、自动复用与刷新路径；AGY 显示 `agy acp --login` 或 `agy`、无需复制 token 与重新检测步骤，保留具体错误原因。
  - 验收：全部 AGY 空态可见文字不含 `Gemini`、`agy login` 或手填账号导向；已有本地 tokens、陈旧值与刷新行为保留。
- [x] 2. **常规任务**：更新 `SettingsPanelView.swift` 的厂商说明与 Gemini/DeepSeek 表单提示，以及 `AboutPanelView.swift` 的产品描述。
  - 验收：配置页明确 AGY / Gemini 对应工具、自动登录路径、旧列表通过「添加模型厂商 → 添加 AGY」恢复步骤；Codex 有先运行并使用工具的提示；OpenCode 如实说明当前为预留标签、原生用量探针尚未接入且可在配置页移除；DeepSeek 区分 API Key 余额与本地估算。
  - 验收：Gemini 三种凭据状态准确，手动邮箱/token/可选 Project ID 标为高级覆盖，保留优先级、验证保存和删除行为；关于页范围准确，版本/构建号不丢失。
- [x] 3. **常规任务**：更新根 `README.md` 与 `app/README.md`。
  - 验收：根 README 包含如何使用、五厂商登录/数据来源表、AGY 与 Gemini 区别、缺少 AGY 标签的恢复步骤；App README 有简版步骤与有效相对链接。
  - 验收：支持范围与默认列表吻合 `ProviderCatalog`；Codex 实时/回退、AGY 今日 tokens、估算和未知值说明准确；原生 Swift 日常运行不要求 Python/仓库路径；如提及打包脚本仍复制 Python 文件，明确与运行时区分。
  - 验收：构建命令按所在目录可执行，环境变量与隐私表述经代码核对，无真实凭据、无过时的仅两厂商/子进程注入/完全离线描述。
- [x] 4. **常规任务**：在 `PanelRenderTests.swift` 补充与本需求对应的文案断言和渲染覆盖。
  - 验收：保留 `testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance` 及既有断言；检查实际 UI 提示而非仅探针状态，覆盖 AGY missing/denied/isolated/expired、Gemini 未配置/CLI/手动覆盖、升级指引及关于页。
  - 验收：断言 AGY 命令有效且空态无 Gemini 指导；使用 fixtures、不访问真实凭据；复用现有三主题/显示档位渲染机制并检查新增长文字与滚动内容可读，不以非空截图作为唯一文案证据。
- [x] 5. **常规任务**：运行自测、打包与实际 App 验收，将证据记入本文件。
  - 验收：仓库根执行 `swift test --package-path app` 和 `app/Scripts/build-app.sh` 均退出 0，记录命令、退出码、测试汇总、产物 `app/dist/UsageLens.app`。环境阻碍须如实记录，不标为通过，也不擅改构建脚本/依赖。
  - 验收：实际启动打包 App，核查菜单栏入口、厂商切换、设置添加 AGY、刷新/重新检测、关于页及帮助提示；确认新增文字在三主题和现有显示档位下不遮挡按钮、可完整阅读。用隔离配置或测试数据模拟旧列表，不覆盖个人凭据/配置；记录步骤、结果与截图证据位置，不记录密钥。
- [x] 6. **常规任务**：交接独立审查及 tech_lead 验收。
  - 验收：停止实现写入后交给 reviewer，核查全部已提交/未提交改动、上述证据及 coder_local 分工/合法替代记录；reviewer 按项目协议输出 `review_report.md`，首行为 `VERDICT: PASS` 才可交由 tech_lead 收尾；REJECT 按串行流程修复复核。该报告由后续 reviewer 创建，不属于本次 researcher 三文件交付。

## 实现验证记录（待 coder 填写）

- **Coder 分工与替代证据**：按 `AGENTS.md` §2.2 先实际探测 `opencode run -m local-vllm/Qwen3.8-27B "Reply with PONG only."` -> 退出码 `1`，报错 `Error: Model unavailable: local-vllm/Qwen3.8-27B`；证据见 `openspec/changes/user-usage-guidance-and-readme/coder-local-probe-evidence.md`，已登记 `.orca-relay/decisions.tsv`、`.orca-relay/state.json` 并明确告知用户后由 `agy` 代替编码。
- **测试命令 / 退出码 / 汇总**：
  - 命令：`swift test --package-path app && git diff --check`
  - 退出码：`0`（0 编译警告）
  - 汇总：`124/124` 通过（`UsageLensKitTests`: 90/90；`UsageLensUITests`: 34/34，含保留的 `testAgyDiagnosticEmptyStatesRenderActionablyWithoutGeminiGuidance` 与新增的 `testUserUsageGuidanceCopyAndHostedRenderAcrossThemesAndScales`）
- **打包命令 / 退出码 / 产物**：
  - 命令：`app/Scripts/build-app.sh`（仓库根执行，OpenCode 修正后重打）
  - 退出码：`0`（9.93s）
  - 产物：`app/dist/UsageLens.app`（`Identifier=dev.usage-lens.UsageLens`，arm64，`Signature=adhoc`，Executable SHA-256: `3462358f95eb0e48ab8728dcb43ba31229eb9c63a4f4885956b1d4aa1295960c`）
- **实际运行步骤 / 主题和缩放 / 结果及证据路径**：
  - 隔离配置实测启动打包产物：`HOME=<mktemp -d>` + `AGY_DISABLE_LOCAL_AUTH=1` + `GEMINI_DISABLE_LOCAL_AUTH=1` + `USAGE_LENS_DEBUG_SUMMARY=1` + `USAGE_LENS_SHOW_PANEL=1` 运行 `app/dist/UsageLens.app/Contents/MacOS/UsageLens -usageLens.providers codex,gemini,opencode`（模拟旧版已保存厂商列表且零接触个人凭据/配置），运行 2.5s 保持存活并输出脱敏状态摘要 `[usage-lens] menubar="(无数据，仅图标)" codex=warning[used=-] gemini=warning[used=-] opencode=missing[used=-][err=OpenCode 暂未接入原生用量探针]`，随后优雅终止。
  - 三主题（`system` / `tech` / `anime`）× 四显示档位（`compact` / `standard` / `comfortable` / `large`）真实 AppKit 离屏渲染截图共 48 张已生成于 `app/.preview/27-about-five-providers-*.png`、`28-settings-guidance-*.png`、`29-panel-agy-guidance-*.png`、`30-panel-gemini-guidance-*.png`；已人工逐张核查紧凑屏（`compact`）下 `About`、`Settings`（含底部展开表单与滚动区）、`AGY` 空态、`Gemini` 空态截图，首轮巡检发现紧凑屏 Gemini Token 输入框占位文字轻微截断，收短占位文案后复跑 124/124 并复查 `28-settings-guidance-tech-compact.png` 确认无截断、无遮挡、按钮与文案均完整可读。
  - 负责人实测确认（2026-11-22 20:44:44 +0800）：在提供最新版 `app/dist/UsageLens.app`（SHA-256 `3462358f95eb0e48ab8728dcb43ba31229eb9c63a4f4885956b1d4aa1295960c`）启动命令后，仓库负责人明确回复「已验证，复审并提交」，确认打包 App 验收通过并授权进入最终独立 Codex 复审与本地提交（不伪造未记录的逐按钮明细日志，不含真实凭据）。
- **独立审查结果**：Round 2 独立只读 Codex 复审通过（`review_report.md` 首行 `VERDICT: PASS`，2026-11-22），`tech_lead` 已验收、本地提交并回到 `IDLE`。
