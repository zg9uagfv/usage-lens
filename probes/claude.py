#!/usr/bin/env python3
"""usage-lens Claude Code 探针。

只读本机 Claude Code 会话日志，输出 usage-lens/probe@1 JSON 到 stdout。
契约见 docs/ARCHITECTURE.md 第 1 节。

数据来源：~/.claude/projects/*/*.jsonl
每个会话一个 JSONL，逐行一个事件；type=="assistant" 行的 message.usage
是 Anthropic 原始 usage 对象（input_tokens / output_tokens /
cache_creation_input_tokens / cache_read_input_tokens），message.model
是模型名，timestamp 是 ISO8601 UTC。

与 Codex 的关键差别：Claude Code 的「5 小时 / 每周」窗口进度是服务端内存态，
不落盘，本地拿不到 used_percent——所以 windows 恒为空数组，不编百分比
（与 DeepSeek 同口径）。能给的只有：
  1. 今日 tokens：主口径 = input + output（cache 单列在 warnings，避免主数字失真）。
  2. 花费估算：内置 Anthropic 公开牌价（USD/百万 tokens），非官方账单。

不读 ~/.claude.json 的凭据、不读 Keychain、不发网络；account.label 恒 null。
model=="<synthetic>" 的行是本地生成的错误/提示消息，usage 全 0，跳过。
仅用标准库，兼容 Python 3.9。
"""

from __future__ import annotations

import datetime
import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCHEMA = "usage-lens/probe@1"
PROVIDER = "claude"

PROJECTS_DIR = Path.home() / ".claude" / "projects"

# 会话日志最多回扫多少个；按 mtime 倒序，仍从最新往旧。
MAX_CANDIDATE_FILES = 200
# 单文件最多读多少字节（会话 JSONL 一般 < 1MB，2MB 足够兜底）。
MAX_SCAN_BYTES = 2 * 1024 * 1024
# App 的「近 7 天花费」口径，用于 spend.window
SPEND_WINDOW_DAYS = 7

# 本地只有 token 数、没有费用字段时用这张牌价折算。
# 来源：Anthropic 公开牌价（按模型），单位 USD / 百万 tokens。牌价会变，仅作估算。
# 未识别的模型按家族前缀兜底（opus 最贵、haiku 最便宜、其余按 sonnet），并给 warning。
PRICE_PER_MILLION_TOKENS_USD = {
    "opus": {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5},
    "sonnet": {"input": 3.0, "output": 15.0, "cache_write": 3.75, "cache_read": 0.3},
    "haiku": {"input": 1.0, "output": 5.0, "cache_write": 1.25, "cache_read": 0.1},
}
# 完全无法识别模型家族时用 Sonnet 档（最常见）。
_FALLBACK_FAMILY = "sonnet"
DEFAULT_CURRENCY = "USD"


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/claude: %s\n" % message)


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def to_utc_iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def _as_number(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value)
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(number) or number < 0:
        return None
    return number


def _price_family(model: str) -> Tuple[str, bool]:
    """按模型名归类到价格家族。返回 (family, 是否识别)。"""
    if not isinstance(model, str) or not model:
        return _FALLBACK_FAMILY, False
    lowered = model.lower()
    for family in ("opus", "sonnet", "haiku"):
        if family in lowered:
            return family, True
    return _FALLBACK_FAMILY, False


def _file_date(path: Path) -> datetime.date:
    try:
        return datetime.datetime.fromtimestamp(path.stat().st_mtime).date()
    except OSError:
        return datetime.date.today()


class _DayBucket:
    """按天累计的 token 分桶 + 估算花费。"""
    __slots__ = ("tin", "tout", "cache_write", "cache_read", "cost")

    def __init__(self) -> None:
        self.tin = 0.0
        self.tout = 0.0
        self.cache_write = 0.0
        self.cache_read = 0.0
        self.cost = 0.0


def _usage_from_event(event: dict) -> Optional[Tuple[dict, str, Optional[float]]]:
    """从一条事件取 (usage, model, epoch)。不是有效 assistant 行返回 None。"""
    if event.get("type") != "assistant":
        return None
    message = event.get("message")
    if not isinstance(message, dict):
        return None
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    model = message.get("model")
    if model == "<synthetic>":
        return None  # 本地生成的错误/提示消息，usage 全 0
    epoch = parse_iso_epoch(event.get("timestamp"))
    model_str = model if isinstance(model, str) else ""
    return usage, model_str, epoch


def _estimate_cost(tin: float, tout: float, cache_write: float, cache_read: float,
                   model: str) -> float:
    family, _ = _price_family(model)
    price = PRICE_PER_MILLION_TOKENS_USD[family]
    return (
        tin * price["input"]
        + tout * price["output"]
        + cache_write * price["cache_write"]
        + cache_read * price["cache_read"]
    ) / 1_000_000.0


def collect_usage(projects_dir: Path) -> Tuple[Dict[datetime.date, _DayBucket], List[str], int,
                                                Optional[datetime.date], Optional[datetime.date]]:
    """扫所有会话 JSONL，按本地日期分桶。

    返回 (按天 buckets, warnings, 用到的文件数, 覆盖起始日, 覆盖结束日)。
    """
    warnings: List[str] = []
    if not projects_dir.is_dir():
        warnings.append("未找到 ~/.claude/projects 目录（Claude Code 可能未安装或从未运行）")
        return {}, warnings, 0, None, None

    try:
        paths = [path for path in projects_dir.glob("*/*.jsonl") if path.is_file()]
    except OSError as exc:
        warnings.append("读取 ~/.claude/projects 失败：%s" % exc)
        return {}, warnings, 0, None, None

    if not paths:
        warnings.append("~/.claude/projects 下没有会话日志")
        return {}, warnings, 0, None, None

    # 按 mtime 倒序，最新优先；超过上限只扫最近的部分
    candidates: List[Tuple[float, str, Path]] = []
    for path in paths:
        try:
            candidates.append((path.stat().st_mtime, str(path), path))
        except OSError:
            warnings.append("跳过 1 个无法读取的会话日志")
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    if len(candidates) > MAX_CANDIDATE_FILES:
        warnings.append("会话日志较多，只统计最近 %d 个" % MAX_CANDIDATE_FILES)
        candidates = candidates[:MAX_CANDIDATE_FILES]

    daily: Dict[datetime.date, _DayBucket] = {}
    used_files = 0
    truncated = 0
    corrupt_lines = 0
    saw_unknown_model = False
    min_day: Optional[datetime.date] = None
    max_day: Optional[datetime.date] = None

    for _mtime, _name, path in candidates:
        try:
            size = path.stat().st_size
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                lines = [line.strip() for line in handle]
        except OSError:
            warnings.append("跳过 1 个无法读取的会话日志")
            continue
        if size > MAX_SCAN_BYTES:
            truncated += 1

        file_used = False
        for line in lines:
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                corrupt_lines += 1
                continue
            if not isinstance(event, dict):
                continue
            parsed = _usage_from_event(event)
            if parsed is None:
                continue
            usage, model, epoch = parsed

            day = None
            if epoch is not None:
                day = datetime.datetime.fromtimestamp(epoch).astimezone().date()
            if day is None:
                day = _file_date(path)

            bucket = daily.setdefault(day, _DayBucket())
            tin = _as_number(usage.get("input_tokens")) or 0.0
            tout = _as_number(usage.get("output_tokens")) or 0.0
            t_cw = _as_number(usage.get("cache_creation_input_tokens")) or 0.0
            t_cr = _as_number(usage.get("cache_read_input_tokens")) or 0.0
            if tin + tout + t_cw + t_cr <= 0:
                continue

            bucket.tin += tin
            bucket.tout += tout
            bucket.cache_write += t_cw
            bucket.cache_read += t_cr
            if model:
                _family, known = _price_family(model)
                if not known:
                    saw_unknown_model = True
                bucket.cost += _estimate_cost(tin, tout, t_cw, t_cr, model)
            file_used = True

            if min_day is None or day < min_day:
                min_day = day
            if max_day is None or day > max_day:
                max_day = day

        if file_used:
            used_files += 1

    if truncated:
        warnings.append("%d 个会话日志超过 2MB，只统计了前 2MB，可能漏掉更早记录" % truncated)
    if corrupt_lines:
        warnings.append("有 %d 行会话日志无法解析，已跳过" % corrupt_lines)
    if saw_unknown_model:
        warnings.append("部分用量来自未识别的模型，花费按 Sonnet 牌价兜底估算")
    if used_files == 0:
        warnings.append("会话日志里没有可识别的 Claude 用量记录")

    return daily, warnings, used_files, min_day, max_day


def build_payload() -> dict:
    started = time.time()
    warnings: List[str] = []

    now = utc_now()
    generated_at = to_utc_iso(now)
    today = datetime.date.today()

    daily, scan_warnings, used_files, min_day, max_day = collect_usage(PROJECTS_DIR)
    warnings.extend(scan_warnings)

    windows: List[dict] = []  # Claude 本地无窗口进度，恒空
    spend = None
    coverage = None
    usage_block = None

    if daily:
        today_bucket = daily.get(today)
        if today_bucket is not None and (today_bucket.tin + today_bucket.tout) > 0:
            today_tokens = int(today_bucket.tin + today_bucket.tout)
            usage_block = {"today_tokens": today_tokens, "source": "local"}
            cache_today = int(today_bucket.cache_write + today_bucket.cache_read)
            if cache_today > 0:
                warnings.append(
                    "今日另有 cache tokens %d（读 %d / 写 %d），不计入主数字"
                    % (cache_today, int(today_bucket.cache_read), int(today_bucket.cache_write))
                )

        # 花费：按天累计估算
        window_start = today - datetime.timedelta(days=SPEND_WINDOW_DAYS)
        today_cost = 0.0
        window_cost = 0.0
        total_cost = 0.0
        for day in sorted(daily.keys()):
            amount = daily[day].cost
            total_cost += amount
            if day == today:
                today_cost += amount
            if window_start <= day <= today:
                window_cost += amount
        if total_cost > 0:
            spend = {
                "today": round(today_cost, 4),
                "window": round(window_cost, 4),
                "currency": DEFAULT_CURRENCY,
                "source": "estimate",
            }
            coverage = {
                "from": (min_day or today).isoformat(),
                "to": (max_day or today).isoformat(),
                "note": "按会话事件时间逐日聚合（本地时区）；window=近 %d 天；"
                        "花费按 Anthropic 公开牌价估算，非官方账单" % SPEND_WINDOW_DAYS,
            }
    else:
        warnings.append("本地没有可识别的 Claude Code 用量记录，无法显示今日 tokens 与花费")

    payload = {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": generated_at,
        "observed_at": generated_at,
        "stale": False,
        "windows": windows,
        "balance": None,
        "spend": spend,
        "usage": usage_block,
        "coverage": coverage,
        "warnings": warnings,
        "error": None,
    }
    _log("耗时 %.0fms（检查 %d 个文件，命中 %d 天）" % (
        (time.time() - started) * 1000, used_files, len(daily)))
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
        payload["error"] = "读取 Claude Code 用量失败：%s" % exc

    if not emit(payload):
        return 1
    return 0 if payload["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
