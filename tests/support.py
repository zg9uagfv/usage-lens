"""测试公共工具：跑探针、造临时 HOME 与 fixture、验契约、查凭据泄露。

只用标准库（unittest），不依赖 pytest。
"""

from __future__ import annotations

import contextlib
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBES = ROOT / "probes"
PROBE_PYTHON = sys.executable

ZSTD_CANDIDATES = ("/opt/homebrew/bin/zstd",)

SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{5,}"),
    re.compile(r"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])"),
)

HEADER_KEYS = {
    "schema",
    "provider",
    "account",
    "generated_at",
    "observed_at",
    "stale",
    "windows",
    "balance",
    "spend",
    "coverage",
    "warnings",
    "error",
}

WINDOW_KEYS = {
    "id",
    "label",
    "used_percent",
    "window_seconds",
    "resets_at",
    "expired",
    "basis",
}


def zstd_bin() -> str:
    for candidate in ZSTD_CANDIDATES:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("zstd")
    return found or ""


def zstd_available() -> bool:
    return bool(zstd_bin())


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
        "PYTHONDONTWRITEBYTECODE": "1",
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
    return strict_loads(lines[0])


def strict_loads(text: str):
    """严格 JSON：拒绝 NaN / Infinity（App 端 JSONDecoder 也拒绝）。"""

    def reject(token):
        raise ValueError("非法 JSON 常量：%s" % token)

    return json.loads(text, parse_constant=reject)


def write_rollout(path: Path, lines, mtime: int = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def token_count_line(used_primary, used_secondary, resets_primary, resets_secondary,
                     plan="plus", with_rate_limits=True, timestamp="2026-11-11T01:25:26.995Z"):
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
        {"timestamp": timestamp, "ordinal": 1, "type": "event_msg", "payload": payload},
        ensure_ascii=False,
    )


def write_projcache(home: Path, session_id: str, totals: dict, created_at_ms: int) -> Path:
    """真实结构：record.rows.tokenUsage.val.totals（camelCase）。"""
    directory = home / ".dsh" / "storages" / "session_projcache" / "sessions"
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 7,
        "record": {
            "identity": {
                "formatVersion": 4,
                "createdAt": created_at_ms,
                "cwd": "/tmp/workspace",
                "isSeeded": False,
            },
            "rows": {
                "tokenUsage": {
                    "ver": 2,
                    "seq": 2,
                    "val": {"totals": totals, "last": None},
                },
                "sessionStats": {"ver": 1, "seq": 2, "val": {"turns": 1}},
            },
        },
    }
    path = directory / (session_id + ".json")
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def write_usage_archive(home: Path, session_id: str, events) -> Path:
    """写真实形状的 session.v4.jsonl.zstd：事件 data.usage（camelCase）。"""
    binary = zstd_bin()
    if not binary:
        raise unittest_skip("需要 zstd 才能造归档 fixture")
    directory = home / ".dsh" / "sessions" / ("--tmp-workspace--") / session_id
    directory.mkdir(parents=True, exist_ok=True)
    raw = "".join(json.dumps(event, ensure_ascii=False) + "\n" for event in events).encode("utf-8")
    target = directory / "session.v4.jsonl.zstd"
    completed = subprocess.run(
        [binary, "-q", "-o", str(target)],
        input=raw,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError("造 zstd fixture 失败：%s" % completed.stderr.decode("utf-8", "replace"))
    return target


def usage_event(ms, usage, event_type="step/usage"):
    """事件信封（seq/time/data），用量在 data.usage。"""
    return {"type": event_type, "seq": 1, "time": ms, "data": {"usage": usage}}


def unittest_skip(reason: str):
    import unittest

    return unittest.SkipTest(reason)


def assert_no_secrets(testcase, text: str) -> None:
    for pattern in SECRET_PATTERNS:
        match = pattern.search(text)
        testcase.assertIsNone(
            match,
            "输出里出现形似凭据的串：%r" % (match.group(0) if match else ""),
        )


def fingerprint(root: Path):
    """目录指纹：只看文件路径与大小，用来断言探针没写文件。"""
    items = []
    for path in sorted(root.rglob("*")):
        relative_text = str(path.relative_to(root))
        # macOS 解释器会往 $HOME/Library/Caches/com.apple.python 写 stdlib pyc，与探针无关
        if relative_text.startswith("Library/Caches"):
            continue
        if path.is_file():
            relative = str(path.relative_to(root))
            try:
                items.append((relative, path.stat().st_size))
            except OSError:
                items.append((relative, -1))
    return items


class LocalServer:
    """最小 HTTP 服务，记录收到的每个请求（含 Authorization 头），用来测重定向泄露。"""

    def __init__(self, behavior):
        self.requests = []
        requests = self.requests

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                requests.append((self.path, dict(self.headers.items())))
                status, headers, body = behavior(self.path)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self._httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._httpd.server_address[1]
        self.url = "http://127.0.0.1:%d" % self.port
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def close(self):
        with contextlib.suppress(Exception):
            self._httpd.shutdown()
        with contextlib.suppress(Exception):
            self._httpd.server_close()
