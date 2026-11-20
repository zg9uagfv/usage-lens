# UsageLens macOS App

纯 Swift / SwiftUI 原生菜单栏用量看板，零 Python 依赖、零第三方包依赖。完整介绍和主题截图见仓库根目录的 [README](../README.md)。

## 构建与运行

```bash
swift build                     # 编译可执行文件
swift test                      # 原生探针、Kit 单测与界面渲染测试
./Scripts/build-app.sh          # 构建 dist/UsageLens.app 并 ad-hoc 签名
open dist/UsageLens.app         # 启动菜单栏 App
```

所有内置探针（Codex / Gemini / DeepSeek）均以纯 Swift 编译进 `UsageLensKit`，打包后的 `dist/UsageLens.app` 可移至任意目录独立运行。

## 面板与配置

- 菜单栏显示一双定时眨眼的眼睛；点击打开已启用的厂商用量面板。
- 配置页提供科技感、二次元、跟随系统三种主题，以及登录后启动开关。
- DeepSeek API Key 可在配置页安全保存到 macOS 钥匙串，仅在内存内用于官方余额查询。
- 模型厂商启用列表保存在本机配置中；支持启用/移除可用厂商，不提供自定义模型名称录入。
- Codex 与 Gemini 用量均来自本地日志；DeepSeek 花费为本地记录估算，余额查询需要 API Key。

## 开发环境变量

| 变量 | 作用 |
|---|---|
| `USAGE_LENS_REFRESH_SECONDS` | 刷新间隔，默认 60 秒 |
| `USAGE_LENS_DEBUG_SUMMARY` | 设为 `1` 时将脱敏后的状态摘要输出到 stderr |
| `USAGE_LENS_SHOW_PANEL` | 设为 `1` 时额外打开普通窗口，便于开发验收 |

更多数据口径与约束见 [架构文档](../docs/ARCHITECTURE.md)。
