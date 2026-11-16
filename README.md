<div align="center">

# UsageLens

**把 AI 编程工具的用量状态，放进 macOS 菜单栏。**

Codex 配额与本地 token 统计 · DeepSeek 余额与花费估算 · 三种外观主题

</div>

<p align="center">
  <img src="docs/screenshots/tech.png" width="260" alt="科技感主题下的 UsageLens 面板">
  &nbsp;&nbsp;
  <img src="docs/screenshots/anime.png" width="260" alt="二次元主题下的 UsageLens 面板">
  &nbsp;&nbsp;
  <img src="docs/screenshots/system.png" width="260" alt="跟随系统主题下的 UsageLens 面板">
</p>

<p align="center"><sub>科技感 · 二次元 · 跟随系统。截图使用演示数据，不包含真实账号或用量。</sub></p>

<p align="center">
  <img src="docs/screenshots/deepseek.png" width="300" alt="DeepSeek 余额和本地花费估算">
</p>

<p align="center"><sub>DeepSeek 标签页：余额来自官方接口，今日与近 7 天花费为本地估算。</sub></p>

## 这个项目做什么

UsageLens 是一个 SwiftUI macOS 菜单栏用量看板。它从本机 Codex 与 DeepSeek 的日志读取数据，用小面板展示配额窗口、重置时间、余额和用量；不需要打开多个开发工具，也不把本地会话日志上传到 UsageLens 服务。

菜单栏图标是一双会眨眼的眼睛。点击后可以切换 Codex / DeepSeek、手动刷新数据，也可以打开配置页更换主题、管理自定义模型名称或设置登录后启动。

## 当前支持

| 工具 | 显示内容 | 数据来源 |
|---|---|---|
| **Codex** | 5 小时与 7 天配额、重置倒计时、计划类型、今日 tokens | `~/.codex/sessions/` 本地会话日志 |
| **DeepSeek** | 账户余额、今日与近 7 天花费估算 | 官方余额接口 + 本地 DeepSeek 会话记录 |

DeepSeek 余额查询需要 API Key，可在面板的齿轮配置页添加；密钥保存在 macOS 钥匙串，并只传给 DeepSeek 探针。也支持 `DEEPSEEK_API_KEY` 环境变量用于开发。UsageLens 只向 `https://api.deepseek.com` 查询余额；缺少 key 时仍会尝试展示本地花费估算。花费是根据本地 token 记录和公开牌价计算的估值，不等同于官方账单。

### 界面主题

- **科技感**：深色底板与青蓝高亮。
- **二次元**：柔和粉紫色调。
- **跟随系统**：采用 macOS 当前的明暗外观与强调色。

## 安装与运行

需要 macOS 14 或更新版本，以及 Swift 5.9 工具链。

```bash
git clone https://github.com/zg9uagfv/usage-lens.git
cd usage-lens/app
./Scripts/build-app.sh
open dist/UsageLens.app
```

建议在仓库内运行，让 App 能找到 `probes/`。若把 App 移到其他目录，需通过 `USAGE_LENS_ROOT` 指向仓库根目录：

```bash
open --env USAGE_LENS_ROOT=/path/to/usage-lens app/dist/UsageLens.app
```

开发时也可以通过环境变量提供 DeepSeek API Key：

```bash
export DEEPSEEK_API_KEY="你的 DeepSeek API Key"
open app/dist/UsageLens.app
```

开发时也可以直接编译或运行测试：

```bash
cd app
swift build
swift test
```

## 隐私与数据口径

- Codex 与 DeepSeek 的会话记录只在本机读取；UsageLens 不提供云同步或遥测。
- DeepSeek API Key 保存于 macOS 登录钥匙串，不写入普通配置文件或日志；查询余额时会发送给 DeepSeek 官方 API。应用拒绝跟随重定向。
- 没有数据时显示“无数据”，不会把未知值伪装成 `0`；读取失败会显示原因，并在适用时保留上次成功值。
- DeepSeek 没有窗口配额，因此不绘制百分比进度条；本地花费估算会标明来源。
- 配置页里的“自定义模型”目前只保存模型名称，不会生成按模型拆分的用量统计。

## 项目结构

```text
probes/                 Python 探针：读取本机数据并输出统一 JSON
app/Sources/UsageLensKit/ 契约解析、探针运行、状态归约与格式化
app/Sources/UsageLensUI/ SwiftUI 面板、配置页与刷新状态
app/Sources/UsageLens/   macOS 菜单栏入口
app/Tests/               Kit 与界面渲染测试
docs/                    需求、架构与数据来源说明
```

每个探针输出 `usage-lens/probe@1` JSON。App 负责解析和展示，具体数据读取留在独立探针中。

## 文档

- [需求范围](docs/REQUIREMENTS.md)
- [架构与探针契约](docs/ARCHITECTURE.md)
- [Claude 接入评估记录](docs/RESEARCH_claude-usage.md)
- [App 构建与开发说明](app/README.md)

## 当前边界

当前内置 provider 为 Codex 与 DeepSeek。自定义 provider、按模型 / 项目归因、账单报表与导出尚未实现。欢迎通过 Issue 讨论新的数据源与接入方式。
