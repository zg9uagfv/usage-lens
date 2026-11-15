#!/usr/bin/env python3
"""usage-lens Codex 探针。

只读本机 Codex 会话日志，输出 usage-lens/probe@1 JSON 到 stdout。
契约见 docs/ARCHITECTURE.md 第 1 节。

数据来源：~/.codex/sessions/**/rollout-*.jsonl
每条 event_msg/token_count 里的 rate_limits 是服务端给的窗口状态。
按文件 mtime 倒序找，命中最后一条含 rate_limits 的记录即停。

v1 不读 ~/.codex/auth.json，account.label 恒为 null。
仅用标准库，兼容 Python 3.9。
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterator, Optional, Tuple

SCHEMA = "usage-lens/probe@1"
PROVIDER = "codex"

SESSIONS_DIR = Path.home() / ".codex" / "sessions"

# 从文件尾部往前读的块大小；避免为了最后一帧全量扫几十 MB 日志。
TAIL_CHUNK_BYTES = 256 * 1024
# 单文件最多回扫这么多字节，超过就放弃并给出 warning。
MAX_SCAN_BYTES = 4 * 1024 * 1024

# weight 按契约固定：primary = 5 小时，secondary = 7 天。
# 日志里的 window_minutes 优先，缺失时才用这里的兜底值。
WINDOW_SPEC = {
    "primary": {"id": "5h", "label": "5 小时", "window_seconds": 18000},
    "secondary": {"id": "7d", "label": "7 天", "window_seconds": 604800},
}


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/codex: %s\n" % message)


def utc_iso(epoch_seconds: Any) -> Optional[str]:
    """把秒级时间戳转成 UTC ISO8601（秒精度，Z 结尾）。拿不到返回 None。"""
    try:
        value = float(epoch_seconds)
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return None
    try:
        moment = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _iter_lines_reverse(path: Path) -> Iterator[bytes]:
    """从文件末尾往前按块读，逐行倒序产出，跳过空行。"""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        buffered = b""
        consumed = 0
        while position > 0 and consumed < MAX_SCAN_BYTES:
            step = min(TAIL_CHUNK_BYTES, position)
            position -= step
            consumed += step
            handle.seek(position)
            buffered = handle.read(step) + buffered
            parts = buffered.split(b"\n")
            buffered = parts[0]
            for raw in reversed(parts[1:]):
                if raw.strip():
                    yield raw
        # 若因字节上限提前停下，buffered 是半行，别当成损坏行
        if position == 0 and buffered.strip():
            yield buffered


def _rate_limits_from_line(raw: bytes) -> Tuple[Optional[dict], bool]:
    """解析一行。返回 (rate_limits, 是否损坏)。不是目标事件时返回 (None, False)。"""
    try:
        event = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None, True
    if not isinstance(event, dict):
        return None, True
    if event.get("type") != "event_msg":
        return None, False
    payload = event.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None, False
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return None, False
    return rate_limits, False


def _window_entry(key: str, rate_limits: dict) -> Optional[dict]:
    spec = WINDOW_SPEC[key]
    raw = rate_limits.get(key)
    if not isinstance(raw, dict):
        return None

    window_seconds = spec["window_seconds"]
    minutes = raw.get("window_minutes")
    if isinstance(minutes, (int, float)) and minutes > 0:
        window_seconds = int(minutes * 60)

    used_percent = raw.get("used_percent")
    if isinstance(used_percent, bool) or not isinstance(used_percent, (int, float)):
        used_percent = None
    else:
        used_percent = round(float(used_percent), 2)

    return {
        "id": spec["id"],
        "label": spec["label"],
        "used_percent": used_percent,
        "window_seconds": window_seconds,
        "resets_at": utc_iso(raw.get("resets_at")),
        "basis": "server",
    }


def find_latest_rate_limits(sessions_dir: Path) -> Tuple[Optional[dict], Optional[str], list]:
    """按 mtime 倒序找第一条含 rate_limits 的会话。返回 (rate_limits, 文件路径, warnings)。"""
    warnings = []
    if not sessions_dir.is_dir():
        return None, None, ["未找到 ~/.codex/sessions 目录（Codex 可能未安装或从未运行）"]

    try:
        candidates = sorted(
            sessions_dir.rglob("rollout-*.jsonl"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
    except OSError as exc:
        return None, None, ["读取 ~/.codex/sessions 失败：%s" % exc]

    if not candidates:
        return None, None, ["~/.codex/sessions 下没有 rollout-*.jsonl 会话日志"]

    _log("候选日志 %d 个，按 mtime 倒序扫描" % len(candidates))

    corrupt_lines = 0
    for path in candidates:
        try:
            for raw in _iter_lines_reverse(path):
                rate_limits, corrupt = _rate_limits_from_line(raw)
                if corrupt:
                    corrupt_lines += 1
                    continue
                if rate_limits is not None:
                    _log("命中最新一条带 rate_limits 的会话")
                    return rate_limits, str(path), warnings
        except OSError as exc:
            warnings.append("跳过 1 个无法读取的日志：%s" % exc)
            continue
        try:
            if path.stat().st_size > MAX_SCAN_BYTES:
                warnings.append("有会话日志超过 4MB，只回扫了末尾部分")
        except OSError:
            pass

    message = "最近的 Codex 会话日志里没有 rate_limits 记录"
    if corrupt_lines:
        message += "（另有 %d 行日志无法解析）" % corrupt_lines
    warnings.append(message)
    return None, None, warnings


def _empty_payload() -> dict:
    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "windows": [],
        "balance": None,
        "spend": None,
        "coverage": None,
        "warnings": [],
        "error": None,
    }


def build_payload() -> dict:
    started = time.time()
    warnings = []
    rate_limits, source_path, scan_warnings = find_latest_rate_limits(SESSIONS_DIR)
    warnings.extend(scan_warnings)

    windows = []
    plan = None
    if rate_limits is not None:
        for key in ("primary", "secondary"):
            entry = _window_entry(key, rate_limits)
            if entry is not None:
                windows.append(entry)
        plan_value = rate_limits.get("plan_type")
        if isinstance(plan_value, str) and plan_value:
            plan = plan_value

    payload = {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": plan},
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "windows": windows,
        "balance": None,
        "spend": None,
        "coverage": None,
        "warnings": warnings,
        "error": None,
    }
    _log("耗时 %.0fms" % ((time.time() - started) * 1000))
    return payload


def main(argv: list) -> int:
    for arg in argv[1:]:
        if arg != "--json":
            payload = _empty_payload()
            payload["error"] = "不支持的参数：%s（只接受无参数或 --json）" % arg
            emit(payload)
            _log(payload["error"])
            return 2

    try:
        payload = build_payload()
    except Exception as exc:  # 兜底：任何意外都给出 JSON，不崩在 App 面前
        payload = _empty_payload()
        payload["error"] = "读取 Codex 用量失败：%s" % exc
        emit(payload)
        _log(payload["error"])
        return 1

    emit(payload)
    return 0


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
