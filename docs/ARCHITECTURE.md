# usage-lens 架构与探针契约 v1

决定：**provider 适配全部做成独立命令行探针，App 只读 JSON。**
好处是每个 provider 可以单独开发、单独验收、单独替换；App 不需要碰任何凭据或日志格式。

```
probes/codex.py      → stdout: usage-lens/probe@1 JSON
probes/deepseek.py   → stdout: usage-lens/probe@1 JSON
app/                 SwiftUI 菜单栏 App，定时调用探针并渲染
```

provider 列表由 App 侧一张配置表决定（id / 显示名 / 探针路径），**加 provider 只需加探针 + 加一行配置**，不改渲染逻辑。首版只有 codex、deepseek 两个。

## 1. 探针契约（强制）

- 探针必须**无参数或仅接受 `--json`** 运行，从 stdin 不读任何东西。
- 成功：exit 0，stdout 只有一个 JSON 对象；stdout 不许有日志、颜色码、进度提示。
- 失败：stderr 写原因，stdout 仍输出 JSON（见 `error` 字段），exit code 非 0。
- 探针耗时目标 < 400ms（只读本地文件）；网络探针（DeepSeek 余额）超时上限 3s。
- **禁止**输出任何 token / key / 密码明文，禁止写入文件，禁止修改任何应用配置或登录态。
- 走网络时必须只请求官方域名。

### 1.1 JSON 结构

```json
{
  "schema": "usage-lens/probe@1",
  "provider": "codex",
  "account": { "label": "user@example.com", "plan": "plus" },
  "generated_at": "2026-11-15T10:20:00Z",
  "windows": [
    {
      "id": "5h",
      "label": "5 小时",
      "used_percent": 33.0,
      "window_seconds": 18000,
      "resets_at": "2026-11-15T13:00:00Z",
      "basis": "server"
    }
  ],
  "balance": null,
  "spend": null,
  "coverage": { "from": "2026-11-01", "to": "2026-11-15", "note": "本地日志覆盖，非官方账单" },
  "warnings": ["..."],
  "error": null
}
```

字段规则：

| 字段 | 规则 |
|---|---|
| `windows` | 配额窗口数组。**没有窗口概念的服务必须给空数组**，不许编百分比 |
| `used_percent` | 0–100 浮点；拿不到就 `null`，不许填 0 |
| `basis` | `server` = 服务端返回；`local` = 本地推导。App 上要能看出区别 |
| `resets_at` | UTC ISO8601，或 `null` |
| `balance` | `{ "amount": 12.34, "currency": "CNY", "source": "official" }` 或 `null` |
| `spend` | `{ "today": 0.5, "window": 3.2, "currency": "CNY", "source": "estimate" }` 或 `null` |
| `coverage` | 数据实际覆盖区间；无数据时如实写 |
| `warnings` | 人话，直接进 UI。例："余额需要 API key" |
| `error` | 致命错误的人话描述；非空时 App 显示错误态而非 0 |

## 2. 已知数据源（已实测）

**Codex** —— `~/.codex/sessions/**/rollout-*.jsonl`，每行一个事件：
- `event_msg` / `token_count` 的 `rate_limits`：`primary`（`window_minutes: 300`, `used_percent`, `resets_at` 秒级时间戳）、`secondary`（`window_minutes: 10080`）、`plan_type`、`credits`
- `token_usage_record`：`usage.input_tokens / cached_input_tokens / output_tokens / reasoning_output_tokens / total_tokens`
- `turn_context`：`model`、`cwd`
- 取**最后一条**含 `rate_limits` 的记录即当前窗口状态；`account.label` 可从 `~/.codex/auth.json` 的 token 声明里取邮箱，取不到就留 `null`（**不许解析或打印 token 本身**）。

**DeepSeek** —— 无窗口配额，只有余额：官方 `GET https://api.deepseek.com/user/balance`（Bearer key）。花费只能从 `~/.dsh/sessions/**/session.v4.jsonl.zstd` 的 `tokenUsage.totals` 本地估算（需要 `zstd` 解压，本机在 `/opt/homebrew/bin/zstd`）。没有 key 时：`balance: null` + warning「余额需要 API key」，`spend` 照常给估算值。

## 3. App 行为

- 菜单栏常驻图标 + 当前最紧张窗口的短标签（例 `Codex 5h 33%`）。
- 点击弹 popover：两个 tab（Codex / DeepSeek），tab 头显示账号与状态点。
- 每个 window 一行：标签、进度条、`已用 XX%`、`Xh Ym 后重置`。
- 底部：`刷新` 按钮 + `N 分钟前更新`。
- 自动刷新 60s；探针失败显示上一次成功值 + 灰化 + 警告文案。
- 深浅色跟随系统；窗口无数据时显示「无数据」，**绝不显示 0%**。
- 不读取、不落盘、不打印任何凭据。

## 4. 验收口径

1. `python3 probes/codex.py | python3 -m json.tool` 输出合法，且 `windows[0].used_percent` 等于日志最后一帧的 `primary.used_percent`。
2. 伪造日志样本（无 rate_limits / 空目录 / 损坏行）下：探针仍 exit 0，给 `warnings`，`windows` 为空，不崩。
3. `probes/deepseek.py` 在无 key 环境下 exit 0，`balance` 为 null 且有 warning；有 key 时 `balance.source == "official"`。
4. 探针输出里 grep 不到任何形似 token 的字符串（长随机串 / `sk-` 前缀）。
5. App `swift build` 通过；启动后菜单栏出现图标；两个 tab 可切；无数据 provider 显示「无数据」。
6. `pytest` / `unittest` 全绿，含上面 2、3 的用例。
