# UsageLens macOS App

原生 Swift / SwiftUI macOS 菜单栏用量看板。完整使用指南、五厂商对比与主题截图见仓库根目录的 [README](../README.md)。

## 快速使用

1. **在终端登录对应工具**（无需手找 OAuth token）：
   - **AGY（Antigravity）**：终端运行 `agy acp --login`（或 `agy`）浏览器 Google 登录，自动复用本机登录态；
   - **Gemini（Gemini CLI / Code Assist）**：终端运行 `gemini` 浏览器 Google 登录，自动复用 `~/.gemini/oauth_creds.json`（配置页手动表单仅作可选高级覆盖，勿填 API Key）；
   - **Codex**：先在终端运行并使用 `codex` 登录以生成实时会话或本地记录；
   - **OpenCode**：当前为预留标签，原生用量探针尚未接入（无需填 token，可在配置页按需移除）；
   - **DeepSeek**：在配置页验证并保存 API Key 查官方余额，本地花费为估算值。
2. 点击顶部菜单栏「眼睛」图标，切换到对应厂商标签页并点击 **「刷新」**。
3. **升级用户若未看到 AGY 标签**：点击面板右下角 **⚙️ 配置 → 添加模型厂商 → 添加 AGY** 即可（旧版已保存列表不会自动覆写）。

## 构建与运行

在 `app/` 目录下执行：

```bash
swift build                     # 编译可执行文件
swift test                      # Kit 单测与界面渲染测试
./Scripts/build-app.sh          # 构建 dist/UsageLens.app 并 ad-hoc 签名
open dist/UsageLens.app         # 启动菜单栏 App
```

App 运行时使用进程内原生 Swift 探针，**日常运行无需 Python、`probes/` 目录或 `USAGE_LENS_ROOT`**，可直接将 `dist/UsageLens.app` 移到 `/Applications` 或任意目录运行（`build-app.sh` 仍复制 `probes/*.py` 仅作兼容参考资源，不会被原生运行时调用）。

## 面板与配置

- 菜单栏显示一双定时眨眼的眼睛；点击打开已启用的厂商用量面板。
- 默认启用 `Codex`、`AGY`、`Gemini`、`OpenCode`，可在配置页自由增删（含按需添加 `DeepSeek`）。
- 配置页提供科技感、二次元、跟随系统三种主题、各厂商简明使用说明，以及「登录后启动」开关。
- DeepSeek API Key 与 Gemini 可选手动覆盖账号仅在验证成功后写入 macOS 登录钥匙串，由原生探针在进程内按厂商边界隔离读取，不会跨厂商泄露。

## 开发环境变量

以下变量仅按当前原生 Swift 代码中的实际用途提供，正常桌面使用无需配置：

| 变量 | 作用 |
|---|---|
| `USAGE_LENS_REFRESH_SECONDS` | 覆盖默认 60 秒轮询刷新间隔 |
| `USAGE_LENS_DEBUG_SUMMARY` | 设为 `1` 时向 `stderr` 输出脱敏后的状态摘要 |
| `USAGE_LENS_SHOW_PANEL` | 设为 `1` 时额外打开普通窗口，便于桌面验收 |
| `USAGE_LENS_ROOT` | 仅兼容旧定位工具/测试接口，日常运行原生 App 无需设置 |
| `DEEPSEEK_API_KEY` | 开发/测试时为 DeepSeek 探针提供 API Key |
| `GEMINI_PROJECT_ID` / `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT_ID` | 仅对 Gemini 探针提供 Google Cloud 项目路由上下文（不构成登录凭据，且不传给其他厂商） |

更多数据口径与探针契约见 [架构与探针契约](../docs/ARCHITECTURE.md) 与根目录 [README](../README.md)。
