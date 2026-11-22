# Local Coder (`coder_local`) Availability Probe Evidence (`user-usage-guidance-and-readme`)

- **Timestamp**: 2026-11-22 19:44:08 +0800
- **Command**: `opencode run -m local-vllm/Qwen3.8-27B "Reply with PONG only."` (executed outside sandbox with user approval)
- **Exit Code**: `1`
- **Captured Output**:
  ```text
  Error: Model unavailable: local-vllm/Qwen3.8-27B
  ```
- **Disposition (`AGENTS.md` §2.2)**: Local model `local-vllm/Qwen3.8-27B` is unavailable on this host. Per `AGENTS.md` §2.2, `tech_lead` recorded this evidence in `.orca-relay/decisions.tsv` and `.orca-relay/state.json`, switches coding for `user-usage-guidance-and-readme` to `agy`, and explicitly notifies the user.
