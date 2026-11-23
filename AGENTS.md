# AGENTS.md — 项目级工程规范与协作约定

本文件是本仓库的项目级工程约定，适用于在此仓库中工作的 AI Agent。**当当前用户的明确指令与本文件约定发生冲突时，以当前用户指令为准。**

> **协作模式声明**：本仓库采用**契约先行、五角色流水线、受控并行与证据闭环**的 `pstack` 工程协作模式。初始化本文件时，已替换原 `AGENTS.md` 中的旧版串行协作规则，避免多套规则同时生效。

---

## 0. `pstack` 必需依赖与启动自检（强制底座）
本仓库强制要求安装并正确配置 **`pstack`** 插件。Agent 开始任何实质性开发任务前，必须先检查 `pstack` 及当前任务所需技能是否可用，**严禁静默跳过或以普通自由发挥流程替代**。

*   **官方安装来源**：`https://github.com/michael-denyer/pstack-claude`（多引擎适配端口；上游原始项目：`https://github.com/cursor/plugins/tree/main/pstack`）
*   **标准安装命令**：
    *   `agy`：`git clone https://github.com/michael-denyer/pstack-claude && cd pstack-claude && agy plugin install ./plugins/pstack`
    *   `codex`：`codex plugin marketplace add michael-denyer/pstack-claude && codex plugin add pstack@pstack-claude`
    *   `opencode`：`opencode plugin add 'github:michael-denyer/pstack-claude#main'`
*   **可用性检查命令**：`for s in poteto-mode architect swarm interrogate blast-radius no-comments; do test -d "$HOME/.gemini/antigravity/skills/$s" || test -d "$HOME/.gemini/config/plugins/pstack/skills/$s" || { echo "MISSING agy skill: $s"; exit 1; }; done && ls -d "$HOME/.codex/plugins/cache/pstack-claude/pstack"/*/skills/poteto-mode >/dev/null && echo "pstack OK"`
*   **本仓库必需技能清单**：`/poteto-mode`, `/architect`, `/swarm`, `/interrogate`, `/blast-radius`, `/no-comments`

### 启动自检与修复规则
1.  **未安装时**：按照上述官方来源与安装命令完成安装，并运行检查命令验证成功。
2.  **配置缺失时**：若已安装但缺少所需技能或模型路由配置，先完成修复再执行任务。
3.  **权限边界**：若安装或修复过程涉及额外系统权限、外部付费或覆盖用户已有全局配置，必须遵守第 7 节人工确认边界。
4.  **阻塞汇报**：无法安装或验证失败时，如实报告实际错误及阻塞原因，**不得宣称环境已就绪或降级为无 `pstack` 模式偷跑任务**。

---

## 1. 项目概览与核心技术栈
*   **项目定位**：原生 Swift / SwiftUI macOS 菜单栏 AI 用量看板（UsageLens），进程内直接通过原生 Swift 探针读取本机 AI 编程工具（Codex、AGY、Gemini、OpenCode、DeepSeek）的登录态与会话日志，并按需向官方接口查询实时配额或余额，在菜单栏面板中展示配额窗口、重置倒计时、今日 tokens、余额与花费估算。
*   **核心技术栈**：Swift 5.9+（本机 Swift 6.4.2） / SwiftUI + AppKit + Foundation（零第三方 Swift 包依赖） / macOS 登录钥匙串（Keychain）与本机只读会话日志 / Swift Package Manager（`app/Package.swift`）与打包脚本（`app/Scripts/build-app.sh`）；另保留 Python 3 标准库参考探针（`probes/`）与 `unittest` 对照测试（`tests/`）。
*   **运行环境**：macOS 14+（Apple Silicon / arm64） / Swift 5.9+ 工具链（原生 App 运行时不依赖 Python；运行参考探针测试需 Python 3.10+）。

---

## 2. 实际目录结构与并行工作区模式（`/architect` 与 `/swarm` 依据）
仓库核心路径与职责边界如下：
*   `app/Sources/UsageLensKit/` — **核心逻辑与原生探针库（`UsageLensKit`）**：各厂商原生 Swift 探针（`CodexNativeProbe`、`AgyNativeProbe`、`GeminiNativeProbe`、`DeepSeekNativeProbe`、`OpenCodeNativeProbe`）、公共契约与状态归约（`ProbeContract.swift`、`Provider.swift`、`ProviderState.swift`、`ProbeRunner.swift`）、钥匙串凭据存储（`DeepSeekAPIKeyStore.swift`、`GeminiAccountStore.swift`）、脱敏与格式化（`SecretRedactor.swift`、`Formatting.swift`）；纯逻辑无 UI 依赖，可脱离 UI 独立单测。
*   `app/Sources/UsageLensUI/` — **SwiftUI 视图与状态容器（`UsageLensUI`）**：主面板、配置页、关于页（`PanelView.swift`、`SettingsPanelView.swift`、`AboutPanelView.swift`）、主题与多屏缩放（`Theme.swift`、`DisplayScaling.swift`）、状态管理与开机自启（`UsageStore.swift`、`LaunchAtLoginManager.swift`、`MenuBarLabel.swift`）；仅依赖 `UsageLensKit`，支持离屏渲染验证。
*   `app/Sources/UsageLens/` — **macOS 菜单栏可执行入口（`UsageLens`）**：应用主入口与菜单栏眨眼图标管理（`UsageLensApp.swift`、`MenuBarIcon.swift`），组合 `UsageLensKit` 与 `UsageLensUI`。
*   `app/Scripts/` & `app/Resources/` — **打包脚本与应用元数据**：`build-app.sh` 负责构建 `app/dist/UsageLens.app` 并执行 ad-hoc 签名；`Info.plist` 定义菜单栏应用配置。
*   `app/Tests/` — **Swift 自动化测试**：`UsageLensKitTests/` 覆盖探针契约、安全脱敏与生命周期测试；`UsageLensUITests/` 覆盖离屏面板渲染与多屏缩放测试。
*   `probes/` & `tests/` — **Python 参考探针与对照单测**：保留的 Python 参考实现（`agy.py`、`codex.py`、`gemini.py`、`deepseek.py`）与 `unittest` 隔离测试（`tests/test_*.py`），用于契约对照与回归验证，非当前 App 原生运行时。
*   `docs/` & `openspec/` — **工程文档与规格档案**：需求、架构与探针契约文档（`docs/`）及变更规格记录（`openspec/changes/`）。

### 2.1 并行工作区模式（初始化时二选一锁定，禁止运行中混用）
*   **当前启用模式**：`独立工作区模式`（Isolated Worktrees / Branches；避免多并行 Coder 争抢同一 `app/.build` 构建锁）
    *   **模式 A：共享工作区模式（Single Working Tree）**：所有并行 Coder 共用同一工作目录与分支，严格按文件所有权切片隔离；**所有 Coder 严禁切换分支及执行 `git commit`**，统一由 Director 在验证通过后提交。
    *   **模式 B：独立工作区模式（Isolated Worktrees / Branches）**：各并行 Coder 在独立的 `git worktree` 与独立特性分支中开发；各 Coder 完成后提交至各自特性分支，由 Director 统一合并至目标分支后交由 Tester 执行全量验证。

### 2.2 契约冻结与并行安全机制
1.  **公共契约先行**：涉及跨模块修改时，先由 Requirement Analyst 锁定公共接口、类型定义或协议文件（如 `ProbeContract.swift`、`Provider.swift`、`ProviderState.swift`）并**冻结**；下游并行 Coder 仅允许实现接口，严禁擅自修改已冻结的公共契约。
2.  **资源隔离**：启动 `/swarm` 多 Agent 任务时，严禁多个 Coder 抢占同一共享测试资源（如固定端口、同一临时数据库/配置目录或真实钥匙串条目）。
3.  **契约缺陷逃生舱**：若并行 Coder 发现已冻结的公共契约存在设计缺陷，**严禁强行凑 Hack 绕过**，必须立即暂停并上报 Director，由 Requirement Analyst 修订契约后重新派发。
4.  **整合门禁**：所有并行 Coder 退出并交回控制权后，方可进入 Code Reviewer 审查与 Tester 全量验证阶段。

---

## 3. 分层验证与交付证据（Prove It Works 门禁）
完成代码改动后，严禁仅凭静态阅读宣称“已修复”，必须按阶段执行真实验证：

### 3.1 验证命令清单
```bash
# 1. 快速构建与编译检查（SwiftPM 调试构建 + 可选 .app 打包验证）：
swift build --package-path app
./app/Scripts/build-app.sh debug

# 2. 单元测试（全量或按 target 针对性过滤）：
swift test --package-path app
# 针对性示例：swift test --package-path app --filter UsageLensKitTests
# 针对性示例：swift test --package-path app --filter UsageLensUITests

# 3. 隔离集成与参考探针兼容测试（本地回环测试服务，清空代理环境变量避免干扰回环）：
HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= python3 -m unittest discover -s tests
```

### 3.2 分层执行规则
*   **Coder 自测阶段**：编码时仅运行与本模块相关的**针对性快速检查与单元测试**，避免重复执行耗时全量构建。
*   **Tester 门禁阶段（写入冻结后）**：代码审查通过、写入冻结后，由 Tester 执行**一次性的全量构建、静态检查与测试套件**。若后续因修复缺陷又修改了代码，必须重跑受影响范围的检查。
*   **真实集成与 Mock 边界**：单元测试允许使用 Mock；涉及鉴权、钥匙串或外部 HTTPS 协议的集成验证，应优先在**隔离的临时目录（独立 `HOME`）或本地回环测试服务**中运行（严禁污染本机真实钥匙串或 `~/.codex`、`~/.gemini` 等真实用户数据）。若环境缺少真实依赖无法运行集成测试，**必须在交付报告中明确标注“未验证范围”**，不得用 Mock 通过冒充集成成功。

### 3.3 交付证据与基线失败举证
*   **精简与脱敏证据**：交付时记录**执行的命令、退出码（Exit Code）、关键汇总结果及日志文件路径**。保存或分享任何验证日志前，必须先对密钥、Token 与个人隐私数据进行脱敏。
*   **基线失败举证责任**：若宣称某项测试失败属于“仓库原有基线问题”，**必须提供修改前的运行记录、已有 Issue 或可复核证据**；证据不足时必须标记为“原因未确认”并排查。因环境受限无法完成验证时，可交付已完成的代码进展，但**严禁宣称完整验证通过**。

---

## 4. 务实架构与工程纪律（Code Reviewer 审查清单）
在编写或审查代码时，须遵守以下工程底线，同时避免过度设计：

1.  **关注点分离与适度抽象**：
    *   确保核心业务逻辑可脱离 UI/路由独立测试，外部依赖（网络、数据库、系统 API）集中管理。
    *   **反过度设计原则**：不为只有一个调用方的简单逻辑强制抽离抽象接口（Interface）或增加无意义的薄包装层。
2.  **并发安全与结果导向的幂等性**：
    *   根据实际并发场景选择合适的保护机制（如数据库唯一约束、事务、原子操作、单写者队列或互斥锁，而非一刀切加锁）。
    *   可重试操作必须避免产生重复副作用，并验证部分失败后的恢复行为；严禁在日志或报错中打印明文密钥、Token 或完整鉴权 Header。
3.  **边界防御与阻塞调用保护**：
    *   外部输入必须在边界层解析并校验为强类型模型，避免在核心逻辑中传递未校验的弱类型字典。
    *   针对网络请求、外部子进程等**可能长期阻塞的 I/O 调用**显式设置超时时间，并处理限流、鉴权失效等常见异常。
4.  **仓库内部清理与对外兼容性**：
    *   重构**仓库内部未公开接口**时，应一次性迁移所有调用方并立即删除废弃（Legacy）代码与冗余注释（执行 `/no-comments`）。
    *   涉及**对外公开 API、持久化数据格式或已发布客户端协议**的变更，不得直接破坏性删除，必须保留向后兼容或提供平滑迁移方案。

---

## 5. Git 工作区/暂存区保护与受控推送（Fail-Closed）
1.  **基线记录与暂存区隔离**：
    *   开始任务前，Director 先运行 `git status` 与 `git diff --cached` 记录**工作区与暂存区（Index）的初始状态**作为基线。
    *   提交前必须核对完整的 `git diff --cached` 暂存差异：**若暂存区中已存在用户或其他 Agent 提前暂存的归属不明改动，严禁执行自动提交，也不得擅自执行 `git reset` 取消其暂存**，应在交付报告中提示用户手动处理提交。
    *   仅允许精确暂存（`git add <file>`）本任务产生的文件，严禁覆盖或撤销他人改动。
2.  **敏感信息与产物拦截**：
    *   提交前必须检查待提交文件清单与差异内容，严格排除 `.env`、本地凭证/密钥文件、本地用户数据、编译构建产物及临时调试文件（如 `.DS_Store`）。
3.  **默认不推送与可核实推送条件（Fail-Closed）**：
    *   **允许自动推送的分支白名单**：`仅限 feat/*, fix/*, chore/*, zg9uagfv/* 等个人开发分支（严禁自动推送至 main / master）；已核查本仓库（origin: git@github.com:zg9uagfv/usage-lens.git）无 .github/workflows 自动部署钩子`
    *   **触发前提**：仅当任务完整通过第 3 节**最终验证闭环（退出码为 0）**、暂存区无第三方改动，且有**可核实的依据**证明当前分支在白名单内、非受保护分支且不会触发自动部署时，方可先执行 `git fetch` 刷新远端引用，再执行 `git commit` 与 `git push`。
    *   **降级保留本地**：只要**无法核实分支保护状态或部署触发行为**，或推送因远端领先被拒绝（Non-fast-forward），**默认保留本地提交（或工作区状态），严禁强推（`--force`）或改写历史**，并在交付报告中明确说明未自动推送的原因。

---

## 6. 多 Agent 角色流水线、职责边界与降级机制
> **重要边界**：本节允许降级的是**底层执行引擎或模型**；第 0 节规定的 **`pstack` 插件及本仓库必需技能属于强制工作流底座，绝不属于可跳过的降级项**。

### 6.1 标准协作流水线与回环机制
```text
用户提出需求
  ↓
Director（项目调度：接收需求、自检环境、记录 Git 基线、拆解并派发任务）
  ↓
Requirement Analyst（需求分析：输出结构化需求与验收标准，锁定公共契约）
  ↓
Coder（码农：按契约实现代码；支持 /swarm 多 Worker 并行切片）
  ↓
Code Reviewer（代码审查：独立审查 Diff、架构红线与回归风险）──[不通过：打回 Coder 修正]
  ↓
Tester（测试工程师：执行构建、单测与隔离集成测试门禁）────[失败：打回 Coder 修复]
  ↓
Director（项目调度：核对最终证据、执行受控 Git 提交/推送、汇总交付给用户）
```

### 6.2 各角色具体职责、工具路由与权限矩阵

| 角色名称 | 具体职责与交付物 | 对应 `pstack` 技能 | 首选引擎/模型 | 权限与不可用降级退路 |
| :--- | :--- | :--- | :--- | :--- |
| **1. Director**<br>*(项目调度)* | • 接收用户需求，按第 7 节原则自主消除细枝末节歧义；<br>• 执行第 0 节 `pstack` 启动自检与第 5 节 Git 工作区/暂存区基线记录；<br>• 协调上下游流转、处理阻塞异常，并在全流程通过后执行受控提交/推送与最终汇总报告。 | `/poteto-mode`<br>*(主控编排)* | **`agy`** | **权限**：拥有完整读写、终端执行与 Git 推送权（唯一可执行最终 `commit`/`push` 的角色）。<br>**降级**：引擎不可用时降级为具备完整环境权限的主力 Agent。 |
| **2. Requirement Analyst**<br>*(需求分析)* | • 分析需求范围与仓库上下文，输出简洁明确的**功能规格与可量化验收标准（Acceptance Criteria）**；<br>• 涉及跨模块改动时，锁定公共接口/类型契约并冻结，避免下游并行冲突。 | `/architect` | **`codex`** | **权限**：默认只读分析（仅允许写入契约定义或需求规格文档，不写业务实现）。<br>**降级**：降级为高推理主力模型；简单单点 Bug 修复可由 Director 兼任精简规格。 |
| **3. Coder**<br>*(码农)* | • 严格依据需求规格与冻结契约编写功能代码、修复 Bug 或重构；<br>• 执行内部旧代码清理（`/no-comments`），完成本模块的快速自测；<br>• 遇到多文件独立切片任务时，按第 2 节工作区模式并行执行。 | `/swarm`<br>`/no-comments` | **`agy`**<br>*(并行切片可用 **`opencode`**)* | **权限**：仅允许修改分配范围内的业务与测试代码；共享工作区模式下**禁止切分支及 `git commit`**。<br>**降级**：`opencode` 不可用时，由单个 Coder 按文件分批串行实现。 |
| **4. Code Reviewer**<br>*(代码审查)* | • 独立审查 `git diff`，逐条核对第 4 节架构红线、并发安全、敏感信息脱敏与边界异常；<br>• 评估改动对外部调用方的爆炸半径；发现缺陷时列出明确修改意见并打回 Coder。 | `/interrogate`<br>`/blast-radius` | **`codex`** | **权限**：严格**只读审查**，禁止直接修改业务代码（防止裁判兼运动员）。<br>**降级**：降级为高推理模型；**若由 Coder 兼任审查，必须在最终报告中显式披露“缺少独立审查”**。 |
| **5. Tester**<br>*(测试工程师)* | • 补充边界测试用例，在写入冻结后运行第 3 节全量构建、静态检查、单元测试与隔离集成测试；<br>• 收集命令、退出码与脱敏日志作为证据；测试不通过时附带复现日志打回 Coder。 | `Prove it works`<br>*(验证门禁)* | **`agy`** | **权限**：拥有测试执行与测试代码编写权，禁止修改生产业务代码以“凑过测试”。<br>**降级**：降级为具备终端执行权限的可用 Worker。 |

---

## 7. 自主决策与人工确认边界
1.  **默认自主拍板**：在技术选型、命名风格、内部实现路径及局部重构方案上，Agent 必须结合本仓库现有风格与最小复杂度原则（KISS）**自行决策并直接落地**，严禁频繁反问打断用户；仅需在交付报告中简要说明所选方案与理由。
2.  **遇到阻塞时的部分推进原则**：当遇到缺少凭证、工具权限不足、环境缺失或暂存区存在归属不明的并发改动时，**不要直接全局停摆**，应先完成所有不受阻塞的子任务与局部验证，再集中清晰地报告需要用户介入处理的部分。
3.  **必须暂停并请求人工确认的事项（Hard Stop）**：
    *   修改系统级权限配置、覆盖用户全局工具配置、删除核心持久化数据或执行破坏性数据库迁移；
    *   向受保护主干分支推送、执行 `git push --force`、改写远端提交历史或触发外部发版动作；
    *   任何涉及**外部付费 API/资源开通**或**对外发送动作**（如发送外部邮件、即时消息、触发对外 Webhook 等）；
    *   需求存在无法通过代码上下文推断的根本性业务歧义。
