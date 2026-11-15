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
  "observed_at": "2026-11-11T01:25:26Z",
  "stale": false,
  "windows": [
    {
      "id": "5h",
      "label": "5 小时",
      "used_percent": 33.0,
      "window_seconds": 18000,
      "resets_at": "2026-11-15T13:00:00Z",
      "expired": false,
      "basis": "server"
    }
  ],
  "balance": null,
  "spend": null,
  "usage": { "today_tokens": 123456, "source": "local" },
  "coverage": { "from": "2026-11-01", "to": "2026-11-15", "note": "本地日志覆盖，非官方账单" },
  "warnings": ["..."],
  "error": null
}
```

字段规则：

| 字段 | 规则 |
|---|---|
| `windows` | 配额窗口数组。**没有窗口概念的服务必须给空数组**，不许编百分比 |
| `used_percent` | 0–100 浮点；拿不到就 `null`，不许填 0；**越界（<0 或 >100）或 NaN 一律 `null` + warning** |
| `expired` | `resets_at` 已早于 `generated_at` → `true`。App 必须显示「窗口已过期」，不许显示负倒计时 |
| `observed_at` | 数据源那一帧的时间（日志帧时间戳）；拿不到填 `generated_at` |
| `stale` | `observed_at` 距 `generated_at` 超过该窗口长度 → `true`，App 灰化并显示「数据来自 X 前」 |
| `basis` | `server` = 服务端返回；`local` = 本地推导。App 上要能看出区别 |
| `resets_at` | UTC ISO8601，或 `null` |
| `balance` | `{ "amount": 12.34, "currency": "CNY", "source": "official" }` 或 `null` |
| `spend` | `{ "today": 0.5, "window": 3.2, "total": 9.1, "currency": "CNY", "source": "estimate" }` 或 `null`。`window` 固定为**近 7 天**（含今天，按事件日/会话创建日过滤），`total` 为全部可读记录，`today` 为当天；`coverage.note` 必须写明「window=近 7 天，total=全部可读记录」 |
| `usage` | `{ "today_tokens": 123456, "source": "local" }` 或 `null`。目前仅 Codex 使用：当天本地 `token_usage_record.usage.total_tokens` 的累计；日志没有记录时为 `null`，不许显示 0。 |
| `coverage` | 数据实际覆盖区间；无数据时如实写 |
| `warnings` | 人话，直接进 UI。例："余额需要 API key" |
| `error` | 致命错误的人话描述；非空时 App 显示错误态而非 0 |

## 2. 已知数据源（已实测）

**Codex** —— `~/.codex/sessions/**/rollout-*.jsonl`，每行一个事件：
- `event_msg` / `token_count` 的 `rate_limits`：`primary`（`window_minutes: 300`, `used_percent`, `resets_at` 秒级时间戳）、`secondary`（`window_minutes: 10080`）、`plan_type`、`credits`
- `token_usage_record`：`usage.input_tokens / cached_input_tokens / output_tokens / reasoning_output_tokens / total_tokens`
- `turn_context`：`model`、`cwd`
- 取**最后一条**含 `rate_limits` 的记录即当前窗口状态；`account.label` 可从 `~/.codex/auth.json` 的 token 声明里取邮箱，取不到就留 `null`（**不许解析或打印 token 本身**）。

**DeepSeek** —— 无窗口配额，只有余额：官方 `GET https://api.deepseek.com/user/balance`（Bearer key）。花费只能从本地会话记录估算，**两个来源都要支持**：
1. `~/.dsh/storages/session_projcache/sessions/*.json` 的 `record.rows.tokenUsage.val.totals`，键名是 **camelCase**：`uncachedInputTokens` / `outputTokens` / `cacheReadTokens` / `cacheWriteTokens`（已实测确认存在此结构）
2. 会话事件里的 `data.usage`（同样是 camelCase），用于按天拆分；拿不到就按会话聚合，日期用文件 mtime 近似，并在 `coverage.note` 里写明口径

> 注意：`tokenUsage.totals` **不在** session jsonl 的顶层，早期探针按顶层找是错的。
> 需要 `zstd` 解压，本机在 `/opt/homebrew/bin/zstd`。没有 key 时：`balance: null` + warning「余额需要 API key」，`spend` 照常给估算值。

**网络请求硬规则**：只允许请求 `https://api.deepseek.com`。**必须禁止自动重定向**（或校验最终 `geturl()` 的 host 与 scheme），否则 302 会把 `Authorization` 头带到第三方域名——审查已实测复现。

## 3. App 行为

- 菜单栏常驻图标 + 当前最紧张窗口的短标签（例 `Codex 5h 33%`）。
- 点击弹 popover：两个 tab（Codex / DeepSeek），tab 头显示账号与状态点。
- 每个 window 一行：标签、进度条、`已用 XX%`、`Xh Ym 后重置`。
- 底部：`刷新` 按钮 + `N 分钟前更新`。
- 底部提供「登录后启动」开关；用 macOS `SMAppService` 管理，默认关闭。
- 自动刷新 60s；探针失败显示上一次成功值 + 灰化 + 警告文案。
- `expired: true` 的窗口显示「窗口已过期（数据 X 天前）」，不显示倒计时；`stale: true` 的整块灰化。
- 深浅色跟随系统；窗口无数据时显示「无数据」，**绝不显示 0%**。
- 不读取、不落盘、不打印任何凭据。

## 4. 验收口径

1. `python3 probes/codex.py | python3 -m json.tool` 输出合法，且 `windows[0].used_percent` 等于日志最后一帧的 `primary.used_percent`。
2. 伪造日志样本（无 rate_limits / 空目录 / 损坏行）下：探针仍 exit 0，给 `warnings`，`windows` 为空，不崩。
3. `probes/deepseek.py` 在无 key 环境下 exit 0，`balance` 为 null 且有 warning；有 key 时 `balance.source == "official"`。
4. 探针输出里 grep 不到任何形似 token 的字符串（长随机串 / `sk-` 前缀）。
5. App `swift build` 通过；启动后菜单栏出现图标；两个 tab 可切；无数据 provider 显示「无数据」。
6. `pytest` / `unittest` 全绿，含上面 2、3 的用例。
7. **过期数据**：`resets_at` 已过去的窗口 → `expired: true` + warning；`observed_at` 早于窗口长度 → `stale: true`；两者都不许静默当成当前值。
8. **越界与 NaN**：`used_percent` 为 150 / -5 / NaN → 输出 `null` + warning，且输出必须是严格合法 JSON（`NaN` 不算）。
9. **重定向安全**：302 到非 `api.deepseek.com` 的域名时，探针不得发出 `Authorization`；最终 URL 不是 https + 官方域名就报错。
10. **无 key 不发请求**：没有 `DEEPSEEK_API_KEY` 时，探针不得产生任何网络连接。
