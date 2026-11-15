# usage-lens App（macOS 菜单栏）

SwiftUI 菜单栏常驻的配额看板。数据全部来自仓库根目录的探针脚本输出的
`usage-lens/probe@1` JSON —— App 自己不读凭据、不写文件、不发网络请求。

## 结构

```
app/
├── Package.swift
├── Sources/
│   ├── UsageLensKit/   契约解析、仓库定位、跑探针、状态归约、格式化（纯逻辑，可单测）
│   ├── UsageLensUI/    SwiftUI 视图 + UsageStore（60s 轮询）
│   └── UsageLens/      @main：MenuBarExtra + popover 入口
├── Tests/              Kit 单测 + 用 ImageRenderer 离屏渲染面板的界面测试
├── Resources/Info.plist
└── Scripts/build-app.sh
```

## 构建 / 运行

```bash
cd app
swift build                     # 编译（不产生 .app bundle）
swift test                      # 单测 + 界面渲染测试（输出到 .preview/*.png）
./Scripts/build-app.sh          # 打成 dist/UsageLens.app 并 ad-hoc 签名
open dist/UsageLens.app         # 菜单栏常驻，无 Dock 图标
```

> 把 `.app` 装到 `/Applications` 时，App 找不到仓库里的 `probes/`（它会从 bundle 位置向上找）
> → 面板全显示「无数据」。要么把 `probes/` 一起放进去，要么显式指路：
> `open --env USAGE_LENS_ROOT=/path/to/usage-lens dist/UsageLens.app`。

菜单栏使用紧凑的“用量透镜”图标（悬停可查看当前最紧张窗口）；点开是 Codex / DeepSeek 两个 tab，
底部有刷新按钮与「N 分钟前更新」及齿轮配置按钮。Codex 还会显示从当天本地日志累计的「今日 tokens」
（标记为“本地统计”，没有记录时不显示 0）。齿轮配置页可开关“登录后启动”；
它默认关闭，并使用 macOS 系统登录项服务。退出用面板右下角的电源按钮。

> 沙箱环境提示：若 SwiftPM 报 `sandbox-exec: sandbox_apply: Operation not permitted`
> （例如在受限沙箱里），用 `SWIFT_BUILD_FLAGS=--disable-sandbox ./Scripts/build-app.sh`
> 追加参数即可；普通机器不需要。

## provider 配置

`Sources/UsageLensKit/Provider.swift` 里的 `ProviderCatalog.all` 是一张配置表：

```swift
Provider(id: "codex", displayName: "Codex", probeRelativePath: "probes/codex.py")
```

加 provider = 加一个探针脚本 + 在这里加一行 + 追加进 `all`。渲染、状态、tab 都不用改。

## 开发用环境变量（正常使用不需要）

| 变量 | 作用 |
|---|---|
| `USAGE_LENS_ROOT` | 指定仓库根（找 `probes/`），用于测试假探针或别的 worktree |
| `USAGE_LENS_REFRESH_SECONDS` | 改轮询间隔，默认 60 |
| `USAGE_LENS_DEBUG_SUMMARY` | `1` 时每轮把状态打到 stderr，便于验收/排障 |
| `USAGE_LENS_SHOW_PANEL` | `1` 时额外打开普通窗口，便于菜单栏被隐藏时验收；正常使用不设置 |

## 状态约定

- 没有数据（含探针不存在）→「无数据」，绝不显示 0%。
- `used_percent: null` →「未知」，进度条只画虚线轨道。
- 探针失败 → 保留上次成功值、灰化，并显示失败原因与 warnings。
- `expired: true`（或 `resets_at` 已过去）→「窗口已过期（数据 X 天前）」，不显示倒计时。
- `stale: true` → 整块灰化 + 「数据来自 X 天前」，且不上菜单栏。
- `schema` 不是 `usage-lens/probe@1` → 整份输出作废：不渲染任何数字，显示「探针输出格式不兼容」。
- 菜单栏只显示 `ok` 且未 stale、未 expired 的窗口；否则退回纯图标。
- DeepSeek 没有窗口概念 → 不画百分比，只显示余额/花费与 warnings。
