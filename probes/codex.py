#!/usr/bin/env python3
"""usage-lens Codex 探针。

只读本机 Codex 会话日志，输出 usage-lens/probe@1 JSON 到 stdout。
契约见 docs/ARCHITECTURE.md 第 1 节。

数据来源：~/.codex/sessions/**/rollout-*.jsonl
每条 event_msg/token_count 里的 rate_limits 是服务端给的窗口状态；
当天 token_usage_record.usage.total_tokens 是本地的「今日 tokens」统计。

选帧规则（可复核）：在所有候选日志里取「事件时间戳最大」的 rate_limits 帧。
文件按 mtime 倒序扫，一旦已命中帧且某文件 mtime 早于该帧时间，就不必再往后看。
这样即使两个文件 mtime 相同，结果也只由内容决定，不依赖目录枚举顺序。

v1 不读 ~/.codex/auth.json，account.label 恒为 null。
仅用标准库，兼容 Python 3.9。
"""

from __future__ import annotations

import datetime
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterator, List, Optional, Tuple

SCHEMA = "usage-lens/probe@1"
PROVIDER = "codex"

SESSIONS_DIR = Path.home() / ".codex" / "sessions"

# 从文件尾部往前读的块大小；避免为了最后一帧全量扫几十 MB 日志。
TAIL_CHUNK_BYTES = 256 * 1024
# 单文件最多回扫这么多字节，超过就放弃并给出 warning。
MAX_SCAN_BYTES = 4 * 1024 * 1024
# 最多检查多少个候选文件；仍然从最新往旧扫。
MAX_CANDIDATE_FILES = 50

# 「今日 tokens」只扫描当天有修改的日志，并沿用每个文件 4MB 的尾扫上限。
# 这是本地估算：日志被截断或稍后才落盘时，宁可提示不完整也不编造精确值。
TODAY_TOKEN_SCAN_FILES = 50

# 契约固定：primary = 5 小时，secondary = 7 天。
# 日志里的 window_minutes 优先（换算成秒），缺失时才用这里的兜底值。
WINDOW_SPEC = {
    "primary": {"id": "5h", "label": "5 小时", "window_seconds": 18000},
    "secondary": {"id": "7d", "label": "7 天", "window_seconds": 604800},
}


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/codex: %s\n" % message)


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def to_utc_iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_to_iso(epoch_seconds: Any) -> Optional[str]:
    """把秒级时间戳转成 UTC ISO8601（秒精度，Z 结尾）。拿不到返回 None。"""
    if isinstance(epoch_seconds, bool):
        return None
    try:
        value = float(epoch_seconds)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value) or value <= 0:
        return None
    try:
        moment = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return to_utc_iso(moment)


def parse_iso_epoch(text: Any) -> Optional[float]:
    """ISO8601 字符串 -> epoch 秒。解析不了返回 None。"""
    if not isinstance(text, str) or not text:
        return None
    try:
        moment = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.timestamp()


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


def _parse_frame(raw: bytes) -> Tuple[Optional[dict], bool]:
    """解析一行。返回 (rate_limits 或 None, 是否损坏)。"""
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
    event_time = parse_iso_epoch(event.get("timestamp"))
    return {
        "rate_limits": rate_limits,
        "timestamp": event.get("timestamp"),
        "epoch": event_time,
    }, False


def _today_token_record(raw: bytes, today: datetime.date) -> Tuple[Optional[int], bool]:
    """从一行 token_usage_record 取 total_tokens；返回 (tokens, 是否损坏)。"""
    try:
        event = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None, True
    if not isinstance(event, dict):
        return None, True

    payload = event.get("payload")
    payload_type = payload.get("type") if isinstance(payload, dict) else None
    if event.get("type") != "token_usage_record" and payload_type != "token_usage_record":
        return None, False

    epoch = parse_iso_epoch(event.get("timestamp"))
    if epoch is None:
        return None, False
    if datetime.datetime.fromtimestamp(epoch).date() != today:
        return None, False

    # 当前 Codex 日志把 type 放在事件顶层、usage 放在 payload；早期封装则两者都在 payload。
    usage = payload.get("usage") if isinstance(payload, dict) else event.get("usage")
    if not isinstance(usage, dict):
        return None, False
    value = usage.get("total_tokens")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None, False
    if not math.isfinite(float(value)) or value < 0:
        return None, False
    return int(value), False


def find_today_tokens(sessions_dir: Path, today: datetime.date) -> Tuple[Optional[int], List[str]]:
    """累计当天的 token_usage_record；只读日志，不把未知值当作 0。"""
    if not sessions_dir.is_dir():
        return None, []
    try:
        candidates = [path for path in sessions_dir.rglob("rollout-*.jsonl") if path.is_file()]
    except OSError:
        return None, ["无法读取 Codex 日志，未能统计今日 tokens"]

    try:
        candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError:
        candidates.sort(key=lambda path: str(path), reverse=True)
    candidates = candidates[:TODAY_TOKEN_SCAN_FILES]

    total = 0
    found = False
    truncated = 0
    for path in candidates:
        try:
            # 日志 mtime 早于今天时，后续更旧文件不可能包含正常写入的当天记录。
            if datetime.datetime.fromtimestamp(path.stat().st_mtime).date() < today:
                break
            for raw in _iter_lines_reverse(path):
                value, _ = _today_token_record(raw, today)
                if value is not None:
                    total += value
                    found = True
            if path.stat().st_size > MAX_SCAN_BYTES:
                truncated += 1
        except OSError:
            continue

    warnings: List[str] = []
    if truncated:
        warnings.append("今日 tokens 仅扫描了 %d 个大日志的末尾 4MB，统计可能不完整" % truncated)
    return (total if found else None), warnings


def _last_frame_in_file(path: Path) -> Tuple[Optional[dict], int]:
    """文件里最后一条 rate_limits 帧；没有就 None。同时返回损坏行数。"""
    corrupt_lines = 0
    for raw in _iter_lines_reverse(path):
        frame, corrupt = _parse_frame(raw)
        if corrupt:
            corrupt_lines += 1
            continue
        if frame is not None:
            return frame, corrupt_lines
    return None, corrupt_lines


def find_latest_frame(sessions_dir: Path) -> Tuple[Optional[dict], List[str], int]:
    """按 mtime 倒序扫候选日志，取事件时间最新的帧。返回 (frame, warnings, 扫描文件数)。"""
    warnings: List[str] = []
    if not sessions_dir.is_dir():
        return None, ["未找到 ~/.codex/sessions 目录（Codex 可能未安装或从未运行）"], 0

    try:
        paths = list(sessions_dir.rglob("rollout-*.jsonl"))
    except OSError as exc:
        return None, ["读取 ~/.codex/sessions 失败：%s" % exc], 0

    if not paths:
        return None, ["~/.codex/sessions 下没有 rollout-*.jsonl 会话日志"], 0

    # 单个 stat 失败不能连累其他日志（审查 N5）
    candidates: List[Tuple[float, str, Path]] = []
    for path in paths:
        try:
            candidates.append((path.stat().st_mtime, str(path), path))
        except OSError:
            warnings.append("跳过 1 个无法读取的日志文件")
    if not candidates:
        return None, warnings + ["没有可读的 Codex 会话日志"], 0

    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    if len(candidates) > MAX_CANDIDATE_FILES:
        warnings.append("Codex 会话日志较多，只检查最近 %d 个" % MAX_CANDIDATE_FILES)
        candidates = candidates[:MAX_CANDIDATE_FILES]

    _log("候选日志 %d 个，按 mtime 倒序扫描" % len(candidates))

    best: Optional[dict] = None
    best_key: Optional[Tuple[float, str]] = None
    truncated = 0
    scanned = 0
    corrupt_lines = 0

    for mtime, name, path in candidates:
        # 已命中帧，且该文件 mtime 早于帧时间 -> 后面不可能有更新帧
        if best is not None and mtime < (best["epoch"] or best["fallback_epoch"]):
            break
        scanned += 1
        try:
            frame, corrupt = _last_frame_in_file(path)
        except OSError:
            warnings.append("跳过 1 个无法读取的日志")
            continue
        corrupt_lines += corrupt
        if frame is None:
            try:
                if path.stat().st_size > MAX_SCAN_BYTES:
                    truncated += 1
            except OSError:
                pass
            continue
        frame["fallback_epoch"] = mtime
        frame["path"] = str(path)
        frame["name"] = name
        key = (frame["epoch"] if frame["epoch"] is not None else mtime, name)
        if best_key is None or key > best_key:
            best = frame
            best_key = key

    if best is not None:
        _log("命中最新一条带 rate_limits 的会话")
    else:
        message = "最近的 Codex 会话日志里没有 rate_limits 记录"
        if corrupt_lines:
            message += "（另有 %d 行日志无法解析）" % corrupt_lines
        warnings.append(message)
    if truncated:
        # TODO(N6): 之后给这条 warning 带短标识（日志目录的日期，或对 UUID 文件名开白名单）。
        # 本轮故意不带文件名：UUID 会被「长随机串」泄露断言命中，宁可给计数。
        warnings.append("有 %d 个会话日志超过 4MB，只回扫了末尾部分，可能漏掉更早的帧" % truncated)
    return best, warnings, scanned


def _clean_percent(value: Any, label: str, warnings: List[str]) -> Optional[float]:
    """0–100 之外或非有限值一律 null + warning（不 clamp、不编数）。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number) or number < 0.0 or number > 100.0:
        warnings.append("%s的 used_percent 数值异常（%r，不在 0-100），已置空" % (label, value))
        return None
    return round(number, 2)


def _human_age(seconds: float) -> str:
    if seconds >= 86400:
        return "%d 天前" % int(seconds // 86400)
    if seconds >= 3600:
        return "%d 小时前" % int(seconds // 3600)
    if seconds >= 60:
        return "%d 分钟前" % int(seconds // 60)
    return "刚刚"


def _window_entry(key: str, rate_limits: dict, now: datetime.datetime,
                  observed_at: Optional[str], warnings: List[str]) -> Optional[dict]:
    spec = WINDOW_SPEC[key]
    raw = rate_limits.get(key)
    if not isinstance(raw, dict):
        return None

    window_seconds = spec["window_seconds"]
    minutes = raw.get("window_minutes")
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)):
        pass
    elif math.isfinite(float(minutes)) and minutes > 0:
        window_seconds = int(minutes * 60)

    resets_epoch = None
    resets_raw = raw.get("resets_at")
    if isinstance(resets_raw, (int, float)) and not isinstance(resets_raw, bool):
        candidate = float(resets_raw)
        if math.isfinite(candidate) and candidate > 0:
            resets_epoch = candidate
    resets_at = epoch_to_iso(resets_epoch)

    expired = False
    if resets_epoch is not None and resets_epoch < now.timestamp():
        expired = True
        when = "数据来自 %s" % (observed_at[5:10] if observed_at else "未知日期")
        warnings.append(
            "%s窗口已于 %s重置（%s）" % (
                spec["label"],
                _human_age(now.timestamp() - resets_epoch),
                when,
            )
        )

    return {
        "id": spec["id"],
        "label": spec["label"],
        "used_percent": _clean_percent(raw.get("used_percent"), spec["label"], warnings),
        "window_seconds": window_seconds,
        "resets_at": resets_at,
        "expired": expired,
        "basis": "server",
    }


def build_payload() -> dict:
    started = time.time()
    warnings: List[str] = []
    frame, scan_warnings, scanned = find_latest_frame(SESSIONS_DIR)
    warnings.extend(scan_warnings)

    now = utc_now()
    generated_at = to_utc_iso(now)
    observed_at = generated_at
    windows: List[dict] = []
    plan = None
    coverage = None
    stale = False
    today_tokens, token_warnings = find_today_tokens(SESSIONS_DIR, now.date())
    warnings.extend(token_warnings)

    if frame is not None:
        rate_limits = frame["rate_limits"]
        observed_at = epoch_to_iso(frame["epoch"]) or generated_at
        for key in ("primary", "secondary"):
            entry = _window_entry(key, rate_limits, now, observed_at, warnings)
            if entry is not None:
                windows.append(entry)
        plan_value = rate_limits.get("plan_type")
        if isinstance(plan_value, str) and plan_value:
            plan = plan_value
        if windows:
            frame_day = observed_at[:10]
            coverage = {
                "from": frame_day,
                "to": frame_day,
                "note": "仅最后一帧窗口数据，非官方账单",
            }
            age = now.timestamp() - (frame["epoch"] or now.timestamp())
            # 取最短窗口作为灰化阈值：宁可提示过期，也不装成实时值
            threshold = min(window["window_seconds"] for window in windows)
            stale = age > threshold
            if stale:
                warnings.append(
                    "数据来自 %s（%s），已超过 %d 小时窗口，可能不是当前状态"
                    % (observed_at, _human_age(age), max(threshold // 3600, 1))
                )

    payload = {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": plan},
        "generated_at": generated_at,
        "observed_at": observed_at,
        "stale": stale,
        "windows": windows,
        "balance": None,
        "spend": None,
        "usage": (
            {"today_tokens": today_tokens, "source": "local"}
            if today_tokens is not None else None
        ),
        "coverage": coverage,
        "warnings": warnings,
        "error": None,
    }
    _log("耗时 %.0fms（检查 %d 个文件）" % ((time.time() - started) * 1000, scanned))
    return payload


def _empty_payload() -> dict:
    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": to_utc_iso(utc_now()),
        "observed_at": to_utc_iso(utc_now()),
        "stale": False,
        "windows": [],
        "balance": None,
        "spend": None,
        "usage": None,
        "coverage": None,
        "warnings": [],
        "error": None,
    }


def emit(payload: dict) -> bool:
    """stdout 只能是严格合法 JSON：NaN/Infinity 一律不许出现。"""
    try:
        text = json.dumps(payload, ensure_ascii=False, allow_nan=False)
    except ValueError:
        fallback = _empty_payload()
        fallback["error"] = "输出包含非法数值，已中止本次结果"
        sys.stdout.write(json.dumps(fallback, ensure_ascii=False, allow_nan=False) + "\n")
        sys.stdout.flush()
        _log(fallback["error"])
        return False
    sys.stdout.write(text + "\n")
    sys.stdout.flush()
    return True


def main(argv: List[str]) -> int:
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

    if not emit(payload):
        return 1
    return 0 if payload["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
