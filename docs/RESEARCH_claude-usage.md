# RESEARCH · Claude Code 用量窗口

> **状态：已决定不做（用户 2026-11-15 决定，首版只做 Codex + DeepSeek）。**
> 此文档仅作存档：将来要加 Claude tab 时按下面结论接探针即可，App 侧不用改。

调研时点：2026-11-15。技术主管代做（研究员两次传输失败）；结论来自第三方文档 + 本机 keychain 存在性实测，未做真实接口验证。

## 结论表

| 项 | 结论 |
|---|---|
| 是否可行 | **可行**（只读，不刷新凭据） |
| 数据来源 | `GET https://api.anthropic.com/api/oauth/usage` |
| 鉴权 | `Authorization: Bearer <accessToken>`，token 来自钥匙串项 `Claude Code-credentials` 的 `claudeAiOauth.accessToken` |
| 必需 header | `anthropic-beta: oauth-2025-04-20`、`anthropic-version: 2023-06-01` |
| 关键字段 | `five_hour.utilization`（0–100）、`five_hour.resets_at`（RFC3339）；`seven_day.utilization`、`seven_day.resets_at`；`extra_usage.is_enabled` |
| 窗口口径 | 5 小时 **滚动**窗口（resets_at 随使用滑动），7 天窗口每周重置 |
| 权限要求 | macOS 读钥匙串：`security find-generic-password -s 'Claude Code-credentials'`；首次由 App 调用会弹系统授权 |
| 频率限制 | 端点自带冷却，**60 秒下限**，实测约 160 秒后才行；超限返回 429 + `Retry-After` |
| 风险 | 见下 |

## 证据

- 端点与返回结构：[claude-code-usage-indicator 的 frozen schema 文档](https://raw.githubusercontent.com/orbenozio/claude-code-usage-indicator/9f1f5fb57f67eb40afeb2fe9f8838f9dedd3c93a/docs/usage-endpoint.md)（第三方文档，非官方 API 文档）
- 官方文档没有公开这个端点：Anthropic API docs 里没有 `/api/oauth/usage` 条目，所以这属于"社区逆向、随时可能变"的接口
- 本机实测：`security find-generic-password -s "Claude Code-credentials"` 返回 `keychain: "~/Library/Keychains/login.keychain-db"`，`class: "genp"` → **钥匙串项存在**（未读取内容）

## 坑与风险

1. **接口非官方**：无文档承诺，Anthropic 改字段或关端点时我们会直接挂。必须做降级：拿不到就显示「Claude：不可用」，不影响其它 tab。
2. **429 冷却**：60 秒轮询会对齐上限，建议默认 5 分钟一次；收到 429 就按 `Retry-After` 退避，绝不硬刷。
3. **token 过期**：我们只读、不刷新（这是有意的）。token 过期时只能显示"上次值 + 已过期"，绝不能自己去 OAuth 刷新——那会和 Claude Code 抢刷新、可能把用户登录态搞坏。这一条是硬红线。
4. **多实例放大限流**：同时开多个实例会加速撞 429，探针要单例。
5. **钥匙串授权**：首次读会弹系统授权框；如果用户点"拒绝"，探针必须优雅降级，不能反复弹。
6. 未验证：本机该 token 是否仍有效、返回体是否与上面字段一致。**这一步必须用户授权后由探针实测。**

## 建议

- 探针 `probes/claude.py` 走只读路径：读钥匙串 → 调端点 → 归一化成契约 JSON；`basis: "server"`
- 默认轮询 5 分钟，收到 429 按 `Retry-After` 退避
- token 失效 → 输出 `error: "凭据已过期，请先打开 Claude Code"` + 保留上次值
- 若用户不接受"依赖非官方接口 + 读钥匙串"，直接砍掉 Claude tab，只做 Codex + DeepSeek
