"""测试公共工具：跑探针、造临时 HOME、验契约、查凭据泄露。

只用标准库（unittest），不依赖 pytest。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBES = ROOT / "probes"
PROBE_PYTHON = sys.executable

SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{5,}"),
    re.compile(r"[A-Za-z0-9_\-]{32,}"),
)

HEADER_KEYS = {
    "schema",
    "provider",
    "account",
    "generated_at",
    "windows",
    "balance",
    "spend",
    "coverage",
    "warnings",
    "error",
}


def make_home(root: Path) -> Path:
    """造一个隔离的 HOME，探针只看这里，绝不碰真实用户目录。"""
    home = root / "home"
    (home / ".codex" / "sessions").mkdir(parents=True, exist_ok=True)
    (home / ".dsh" / "sessions").mkdir(parents=True, exist_ok=True)
    return home


def run_probe(name: str, home: Path, env_extra=None, args=None, timeout=60):
    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "LANG": "en_US.UTF-8",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    env.pop("DEEPSEEK_API_KEY", None)
    if env_extra:
        env.update(env_extra)
    command = [PROBE_PYTHON, str(PROBES / (name + ".py"))]
    if args:
        command.extend(args)
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
        cwd=str(ROOT),
        check=False,
    )


def parse_stdout(completed: subprocess.CompletedProcess) -> dict:
    text = completed.stdout.decode("utf-8")
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise AssertionError(
            "stdout 必须只有一个 JSON 对象，实际 %d 行：%r" % (len(lines), text[:400])
        )
    return json.loads(lines[0])


def write_rollout(path: Path, lines) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")
    return path


def token_count_line(used_primary, used_secondary, resets_primary, resets_secondary,
                     plan="plus", with_rate_limits=True):
    payload = {
        "type": "token_count",
        "info": {
            "total_token_usage": {"input_tokens": 100, "output_tokens": 20, "total_tokens": 120},
            "last_token_usage": {"input_tokens": 10, "output_tokens": 2, "total_tokens": 12},
            "model_context_window": 258400,
        },
    }
    if with_rate_limits:
        payload["rate_limits"] = {
            "limit_id": "codex",
            "primary": {
                "used_percent": used_primary,
                "window_minutes": 300,
                "resets_at": resets_primary,
            },
            "secondary": {
                "used_percent": used_secondary,
                "window_minutes": 10080,
                "resets_at": resets_secondary,
            },
            "credits": {"has_credits": False, "unlimited": False, "balance": "0"},
            "plan_type": plan,
        }
    return json.dumps(
        {"timestamp": "2026-11-11T01:25:26.995Z", "ordinal": 1, "type": "event_msg",
         "payload": payload},
        ensure_ascii=False,
    )


def assert_no_secrets(testcase, text: str) -> None:
    for pattern in SECRET_PATTERNS:
        match = pattern.search(text)
        testcase.assertIsNone(
            match,
            "输出里出现形似凭据的串：%r" % (match.group(0) if match else ""),
        )
