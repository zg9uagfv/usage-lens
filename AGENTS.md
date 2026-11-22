# 多 Agent 串行协作规范与强制规则（AGY / Codex 通用）

本文件为项目级强制协作规范，由 `agy` 与 `codex` 自动加载并共同遵守，适用于本仓库及共享工作区内的所有需求调研、设计、编码、测试、审查与交付任务。

---

## 1. 角色定义与职责分工

项目采用 **4 角色串行接力模式**，所有角色共用唯一共享工作区（默认 `wt-workspace` 及同一分支），同一时间最多允许 **1 个活跃角色** 和 **1 个仓库写入者**。

| 角色 | 运行环境与模型 | 核心职责 | 写权限与硬边界 |
| --- | --- | --- | --- |
| **技术主管 (`tech_lead`)** | `agy`（接盘或调度时可指派 `codex`） | 接收需求并按阶段串行调度各角色；唯一负责维护状态与审批裁决；满足法定条件时亲自或指派
`codex` 接盘；汇总审查结论、验收、本地提交并收尾回 `IDLE`。 | 唯一 `state.json` 写入者；严禁在无合法例外记录的情况下绕过本地 Coder 直接代写常规代码。 |
| **研究员 (`researcher`)** | `codex` | 需求调研与代码库摸底；在 `openspec/changes/<change-id>/` 下编写或更新 `proposal.md`、`specs/` 与 `tasks.md`；在
`tasks.md` 中明确标注每项任务为**常规任务**或**复杂任务**，并给出可验证的验收标准。 | **仅写 OpenSpec
规格文档**；禁止修改业务代码、构建脚本或依赖；完成后交接给 `tech_lead`。 |
| **编码员 (`coder`)** | **首选**：`coder_local`（`opencode` + 本地 `local-vllm/Qwen3.8-27B`）<br>**不可用替代**：`agy` 或 `codex` | 按已确认的 OpenSpec 与
`tasks.md` 完成常规业务代码、前端页面、工具/评测脚本、配置与单元测试；执行本地编译与自测并记录命令与结果；遇复杂模块或卡壳立即上报 `tech_lead`。 |
可写已分配任务范围内的实现/单测、`tasks.md` 状态及
`approval_req.json`；**禁止自批**；涉及改构建脚本、删文件、增删依赖、改既定接口等高风险操作须先提审批并暂停等待；仅在 `tech_lead` 明确授权时可本地提交。 |
| **代码审查员 (`reviewer`)** | `codex` + `$thermos` | 对照 OpenSpec
与工程规范独立审查全部已提交与未提交改动，核对基线、HEAD、改动范围与实测证据；核查是否遵守 Coder 分工与例外登记规则；在 `review_report.md` 首行输出
`VERDICT: PASS` 或 `VERDICT: REJECT`。 | **只读代码库、只写 `review_report.md`**；审查子进程保持只读，审查期间冻结实现写入；不替编码员包办开发。 |

---

## 2. Coder 执行与降级替代强制规则

1. **常规编码强制优先使用本地 Coder（`coder_local`）**
   - 所有常规业务代码、前端页面、工具/评测脚本、配置文件、单元测试的新增与修改，**必须**优先通过 `opencode` 调度本地 `coder_local`（固定模型
   `local-vllm/Qwen3.8-27B`）完成。
   - `agy` 与 `codex` **严禁**以“任务小”、“顺手完成”、“单一契约不便拆分”或“减少交接轮次”为由，未经探测擅自跳过 `coder_local`。

2. **本地 Coder 不可用时的替代规则（`agy` 或 `codex` 代替）**
   - 当经**实际探测**确认 `opencode` 或本地 `local-vllm/Qwen3.8-27B` 不可用（如服务未启动、连接超时、接口报错、模型无响应等）时，**允许由 `agy` 或 `codex`
   代替 `coder_local` 执行编码任务**。
   - 执行替代前**必须**满足：
     1. 保留实际探测的报错输出作为证据；
     2. 在 `.orca-relay/decisions.tsv` 与 `.orca-relay/state.json` 中记录替代原因与证据；
     3. 明确告知用户本次已因本地服务不可用切换至 `agy` 或 `codex` 编码，**禁止静默绕过**。

3. **其他允许 `agy` 或 `codex` 直接编码（接盘）的唯一例外条件**（同样须登记到 `decisions.tsv` 与 `state.json`）：
   - **连续卡壳接盘**：`coder_local` 在同一任务上连续卡壳 2 次（`consecutive_local_stalls >= 2`），触发 `tech_lead`
   强制接盘；接盘时不得清理或覆盖其未提交改动。
   - **明确标注的复杂模块**：OpenSpec `tasks.md` 中由 `researcher` 明确标注为复杂模块（如底层推理引擎集成、核心并发/生命周期调度、高风险安全边界修复）。
   - **用户显式指定**：用户在当前指令中明确要求由 `agy` 或 `codex` 直接编写代码。

---

## 3. 串行接力协议与共享工作区纪律（`.orca-relay/`）

### 3.1 标准接力顺序
```text
tech_lead（接单调度）
  → researcher（调研并编写/更新 OpenSpec）
  → tech_lead（审核规格并派发）
  → coder（优先 coder_local；不可用或满足例外时由 agy/codex 代替，完成编码与自测）
  → reviewer（codex + $thermos 独立审查，输出 review_report.md）
  → tech_lead（PASS 则验收提交并回到 IDLE；REJECT 则调度修复并重新审查）
```

### 3.2 共享工作区保护
- 所有角色共用唯一共享工作区（如 `<REPO_ROOT>/wt-workspace`）与同一分支；**禁止另建 worktree**，禁止为接力搬运代码或私自合并分支。
- 必须保留并接着修改前一角色留下的文件；**禁止擅自执行 `git reset` / `git clean` / `git restore`** 覆盖他人未提交改动。
- 切换角色前，必须确认前一角色及其子进程已完全退出。

### 3.3 状态总线文件（`.orca-relay/`）
- `config.json`：角色定义、模型配置、权限与接力规则。
- `state.json`：当前任务状态（仅 `tech_lead` 可写，采用同目录临时文件原子替换，每次交接递增 `revision`）。
  - 允许状态：`IDLE`、`RESEARCHING`、`CODING`、`AWAITING_APPROVAL`、`TAKEOVER`、`REVIEWING`、`FIXING`、`FINALIZING`。
- `decisions.tsv`：按时间追加每次架构决策、派发、本地不可用替代、接盘与验收结论及证据路径。
- `approval_req.json` / `approval_res.json`：
  - `coder` 遇高风险操作（改构建脚本、删文件、改依赖、改既定接口、越界写入）时写 `approval_req.json` 并立即暂停。
  - `tech_lead` 自主裁决后写入 `approval_res.json`（`APPROVED` 或 `REJECTED`，禁止自批）；仅当 `request_id`、操作、路径与条件全部匹配且为 `APPROVED`
  时才可执行。

---

## 4. 代码审查硬门禁（`reviewer`）

1. `reviewer` 必须覆盖全部已提交与未提交改动，输出 `review_report.md`，且**首行必须为 `VERDICT: PASS` 或 `VERDICT: REJECT`**。
2. 出现以下任一情况，**必须直接判定 `VERDICT: REJECT`**：
   - 缺少必需的单元测试、构建校验或真实运行验证证据；
   - 发现 `agy` 或 `codex` 绕过 `coder_local` 直接编写常规代码，且无“本地不可用探测证据”或其他合法接盘记录；
   - 存在未解决的正确性、安全性或规格偏离阻断项。
3. 判定 `REJECT` 后进入闭环：`tech_lead` 调度修复角色修复 → `reviewer` 复核，直至 `VERDICT: PASS`。

---

## 5. 新项目快速启用清单

1. 将本文件保存为新项目根目录的 `AGENTS.md`（若使用共享工作区 `wt-workspace`，同时同步一份至 `wt-workspace/AGENTS.md`）。
2. 在项目根目录创建 `.orca-relay/`（加入 `.gitignore`），初始化 `config.json`、`state.json`（初始 `status: "IDLE"`, `revision: 0`）和 `decisions.tsv`。
3. 确认本机可执行工具：`agy`、`codex`、`opencode`（及本地模型 `local-vllm/Qwen3.8-27B`）；若新环境无本地模型服务，按第 2.2 节探测留痕后自动由 `agy` 或
`codex` 代替编码。
