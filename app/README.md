# UsageLens macOS App

SwiftUI 菜单栏用量看板。完整介绍和主题截图见仓库根目录的 [README](../README.md)。

## 构建与运行

```bash
swift build                     # 编译可执行文件
swift test                      # Kit 单测与界面渲染测试
./Scripts/build-app.sh          # 构建 dist/UsageLens.app 并 ad-hoc 签名
open dist/UsageLens.app         # 启动菜单栏 App
```

App 通过仓库根目录的 `probes/` 运行探针。若把 `.app` 移出仓库，请指定仓库路径：

```bash
open --env USAGE_LENS_ROOT=/path/to/usage-lens dist/UsageLens.app
```

## 面板与配置

- 菜单栏显示一双定时眨眼的眼睛；点击打开 Codex / DeepSeek 用量面板。
- 配置页提供科技感、二次元、跟随系统三种主题，以及登录后启动开关。
- DeepSeek API Key 可在配置页安全保存到 macOS 钥匙串；它只会注入 DeepSeek 探针进程。
- 自定义模型名称保存在本机配置中；当前不参与按模型拆分的用量统计。
- Codex 今日 token 数来自本地日志；DeepSeek 花费为本地记录估算，余额查询需要 API Key。

## 开发环境变量

| 变量 | 作用 |
|---|---|
| `USAGE_LENS_ROOT` | 指定仓库根目录，用于假探针或其他 worktree |
| `USAGE_LENS_REFRESH_SECONDS` | 刷新间隔，默认 60 秒 |
| `USAGE_LENS_DEBUG_SUMMARY` | 设为 `1` 时将脱敏后的状态摘要输出到 stderr |
| `USAGE_LENS_SHOW_PANEL` | 设为 `1` 时额外打开普通窗口，便于开发验收 |

更多数据口径与探针约束见 [架构与探针契约](../docs/ARCHITECTURE.md)。
