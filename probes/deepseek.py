#!/usr/bin/env python3
"""usage-lens DeepSeek 探针。

DeepSeek 没有窗口配额，所以 windows 恒为空数组——不编百分比。
能拿到的只有两样：
  1. 余额：$DEEPSEEK_API_KEY 存在时请求官方 GET /user/balance（3s 超时）
  2. 花费估算（两个来源，主 → 次）：
     a. ~/.dsh/storages/session_projcache/sessions/*.json 的 record.rows.tokenUsage.val.totals
        真实结构（已实测）：camelCase 的 uncachedInputTokens / outputTokens / cacheReadTokens / cacheWriteTokens
     b. 会话事件 data.usage（camelCase：inputTokens / outputTokens / cacheReadTokens / cacheWriteTokens）
        有事件时间就按天拆；没有就用文件 mtime 近似，并在 coverage.note 写明口径

口径（依据 DSH 源码）：`uncachedInputTokens: usage.inputTokens`，
`totalTokens = inputTokens + outputTokens + cacheRead + cacheWrite`。
也就是说 inputTokens 不含缓存，不能拿它再减 cacheReadTokens（会漏算）。

只读，不落盘，不打印 key；禁止跟随重定向（3xx 一律报错）。
仅用标准库，兼容 Python 3.9。
"""

from __future__ import annotations

import datetime
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest

SCHEMA = "usage-lens/probe@1"
PROVIDER = "deepseek"

BALANCE_URL = "https://api.deepseek.com/user/balance"
BALANCE_TIMEOUT_SECONDS = 3.0
BALANCE_MAX_BYTES = 1024 * 1024
OFFICIAL_HOST = "api.deepseek.com"
OFFICIAL_SCHEME = "https"

DSH_HOME = Path.home() / ".dsh"
PROJCACHE_DIR = DSH_HOME / "storages" / "session_projcache" / "sessions"
SESSIONS_DIR = DSH_HOME / "sessions"

ZSTD_BIN = "/opt/homebrew/bin/zstd"
ZSTD_TIMEOUT_SECONDS = 10
ZSTD_MAX_DECOMPRESSED_BYTES = 64 * 1024 * 1024
SPEND_SCAN_BUDGET_SECONDS = 3.0
SPEND_MAX_FILES = 500

# 只在本地记录只有 token 数、没有费用字段时用这张牌价折算。
# 来源：DeepSeek 公开牌价（deepseek-chat），单位 CNY / 百万 tokens。牌价会变，仅作估算。
PRICE_PER_MILLION_TOKENS_CNY = {
    "input_cache_miss": 2.0,
    "input_cache_hit": 0.2,
    "output": 3.0,
}
# DeepSeek 没有「缓存写入」单独计价，按未命中价计。
DEFAULT_CURRENCY = "CNY"


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/deepseek: %s\n" % message)


_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{5,}"),
    re.compile(r"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{40,}(?![A-Za-z0-9_\-])"),
)


def redact(text: str) -> str:
    """把任何形似凭据的串抹掉，保证 warning / error 不进 UI 也不进日志。"""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[redacted]", text)
    return text


def utc_iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _as_float(value: Any) -> Optional[float]:
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
    if not math.isfinite(number):
        return None
    return number


# ---------------------------------------------------------------- 余额


class _RejectRedirect(urlrequest.HTTPRedirectHandler):
    """任何 3xx 一律不跟随：否则 Authorization 会被带到重定向目标（审查 B3 实测洞）。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urlrequest.build_opener(_RejectRedirect())


def is_official_url(url: str) -> bool:
    """只认 https + api.deepseek.com（默认端口）。"""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if parts.scheme != OFFICIAL_SCHEME:
        return False
    if (parts.hostname or "") != OFFICIAL_HOST:
        return False
    try:
        port = parts.port
    except ValueError:
        return False
    return port in (None, 443)


def _balance_error_message(exc: urlerror.HTTPError) -> str:
    code = exc.code
    if code in (301, 302, 303, 307, 308):
        return "查询 DeepSeek 余额失败：接口返回重定向（HTTP %d），已按安全策略拒绝跟随" % code
    if code == 401:
        return "查询 DeepSeek 余额失败：API key 无效或已过期（HTTP 401）"
    if code == 403:
        return "查询 DeepSeek 余额失败：没有权限（HTTP 403）"
    if code == 429:
        return "查询 DeepSeek 余额失败：请求被限流（HTTP 429），请稍后重试"
    if 500 <= code < 600:
        return "查询 DeepSeek 余额失败：服务暂时不可用（HTTP %d），请稍后重试" % code
    return "查询 DeepSeek 余额失败：HTTP %d" % code


def _parse_balance_body(body: bytes) -> Tuple[Optional[dict], List[str]]:
    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, ["查询 DeepSeek 余额失败：返回不是合法 JSON"]

    infos = data.get("balance_infos") if isinstance(data, dict) else None
    if not isinstance(infos, list) or not infos:
        return None, ["DeepSeek 余额接口没有返回余额明细"]

    warnings: List[str] = []
    usable = [item for item in infos if isinstance(item, dict)]
    if not usable:
        return None, ["DeepSeek 余额接口返回的明细格式不对"]

    chosen = None
    for item in usable:
        if item.get("currency") == DEFAULT_CURRENCY:
            chosen = item
            break
    if chosen is None:
        chosen = usable[0]
        if len(usable) > 1:
            warnings.append("余额有多种币种，已展示 %s" % str(chosen.get("currency") or "未知币种"))

    amount = _as_float(chosen.get("total_balance"))
    if amount is None:
        return None, ["DeepSeek 余额接口没有可读的余额数字"]

    currency = chosen.get("currency")
    if not isinstance(currency, str) or not currency:
        currency = DEFAULT_CURRENCY

    return {"amount": round(amount, 2), "currency": currency, "source": "official"}, warnings


def fetch_balance(api_key: Optional[str]) -> Tuple[Optional[dict], List[str]]:
    """返回 (balance, warnings)。任何失败都不抛，转成 warning。"""
    if not api_key:
        return None, ["余额需要 API key"]

    request = urlrequest.Request(
        BALANCE_URL,
        headers={
            "Authorization": "Bearer " + api_key,
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with _OPENER.open(request, timeout=BALANCE_TIMEOUT_SECONDS) as response:
            final_url = response.geturl()
            if not is_official_url(final_url):
                return None, ["查询 DeepSeek 余额失败：响应最终地址不是官方域名，已拒绝使用"]
            length = response.headers.get("Content-Length") if response.headers else None
            if length is not None:
                try:
                    if int(length) > BALANCE_MAX_BYTES:
                        return None, ["查询 DeepSeek 余额失败：响应体过大（%s 字节），已拒绝读取" % length]
                except (TypeError, ValueError):
                    pass
            body = response.read(BALANCE_MAX_BYTES)
    except urlerror.HTTPError as exc:
        return None, [_balance_error_message(exc)]
    except urlerror.URLError as exc:
        return None, ["查询 DeepSeek 余额失败：网络不可用（%s）" % exc.reason]
    except (TimeoutError, OSError) as exc:
        return None, ["查询 DeepSeek 余额失败：请求超时或中断（%s）" % exc]
    except Exception as exc:  # 兜底，绝不把异常抛给 App
        return None, ["查询 DeepSeek 余额失败：%s" % exc]

    return _parse_balance_body(body)


# ---------------------------------------------------------------- 花费


def _num(mapping: dict, *keys: str) -> float:
    for key in keys:
        value = _as_float(mapping.get(key))
        if value is not None:
            return value
    return 0.0


def _has_any_usage_field(mapping: dict) -> bool:
    for key in (
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheWriteTokens",
        "reasoningTokens",
        "totalTokens",
        "uncachedInputTokens",
    ):
        if _as_float(mapping.get(key)) is not None:
            return True
    return False


def buckets_from_projcache(totals: dict) -> Dict[str, float]:
    """projcache totals：uncached 与 cache 分别记账，inputTokens 不是这里的键。"""
    return {
        "miss": _num(totals, "uncachedInputTokens") + _num(totals, "cacheWriteTokens"),
        "hit": _num(totals, "cacheReadTokens"),
        "out": _num(totals, "outputTokens"),
    }


def buckets_from_usage(usage: dict) -> Dict[str, float]:
    """事件 data.usage：inputTokens 本来就不含缓存，不再减 cacheReadTokens。"""
    return {
        "miss": _num(usage, "inputTokens") + _num(usage, "cacheWriteTokens"),
        "hit": _num(usage, "cacheReadTokens"),
        "out": _num(usage, "outputTokens"),
    }


def _buckets_total(buckets: Dict[str, float]) -> float:
    return buckets.get("miss", 0.0) + buckets.get("hit", 0.0) + buckets.get("out", 0.0)


def estimate_cost(buckets: Dict[str, float]) -> float:
    price = PRICE_PER_MILLION_TOKENS_CNY
    return (
        buckets.get("miss", 0.0) * price["input_cache_miss"]
        + buckets.get("hit", 0.0) * price["input_cache_hit"]
        + buckets.get("out", 0.0) * price["output"]
    ) / 1_000_000.0


def _local_date_from_ms(value: Any) -> Optional[datetime.date]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        return None
    if seconds > 1e11:  # 毫秒
        seconds /= 1000.0
    try:
        return datetime.datetime.fromtimestamp(seconds).date()
    except (OverflowError, OSError, ValueError):
        return None


def _local_date_from_iso(value: Any) -> Optional[datetime.date]:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        return moment.date()
    return moment.astimezone().date()


def _file_date(path: Path) -> datetime.date:
    try:
        return datetime.datetime.fromtimestamp(path.stat().st_mtime).date()
    except OSError:
        return datetime.date.today()


def _read_projcache(path: Path) -> Optional[dict]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    record = data.get("record")
    if not isinstance(record, dict):
        return None
    rows = record.get("rows")
    if not isinstance(rows, dict):
        return None
    token_usage = rows.get("tokenUsage")
    if not isinstance(token_usage, dict):
        return None
    value = token_usage.get("val")
    if not isinstance(value, dict):
        return None
    totals = value.get("totals")
    if not isinstance(totals, dict):
        return None
    identity = record.get("identity")
    created_at = identity.get("createdAt") if isinstance(identity, dict) else None
    day = _local_date_from_ms(created_at)
    return {"totals": totals, "day": day}


def collect_projcache(projcache_dir: Path, warnings: List[str]) -> List[Tuple[datetime.date, Dict[str, float]]]:
    """返回 [(日期, buckets)]；只统计有用量的会话。"""
    if not projcache_dir.is_dir():
        return []
    try:
        files = sorted(projcache_dir.glob("*.json"))
    except OSError as exc:
        warnings.append("读取 projcache 目录失败：%s" % exc)
        return []

    sessions: List[Tuple[datetime.date, Dict[str, float]]] = []
    unreadable = 0
    zero_sessions = 0
    for path in files:
        parsed = _read_projcache(path)
        if parsed is None:
            unreadable += 1
            continue
        buckets = buckets_from_projcache(parsed["totals"])
        if _buckets_total(buckets) <= 0:
            zero_sessions += 1
            continue
        day = parsed["day"] or _file_date(path)
        sessions.append((day, buckets))

    if unreadable:
        warnings.append("跳过 %d 个无法解析的 projcache 文件" % unreadable)
    if zero_sessions and not sessions:
        warnings.append("projcache 里的 token 用量为 0")
    return sessions


def _resolve_zstd() -> Optional[str]:
    if os.path.isfile(ZSTD_BIN) and os.access(ZSTD_BIN, os.X_OK):
        return ZSTD_BIN
    found = shutil.which("zstd")
    return found


def _read_zstd_text(path: Path, zstd_bin: str) -> Tuple[str, bool]:
    """解压到内存，但有上限。返回 (文本, 是否被截断)。"""
    process = subprocess.Popen(
        [zstd_bin, "-dc", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        data = process.stdout.read(ZSTD_MAX_DECOMPRESSED_BYTES + 1) if process.stdout else b""
    finally:
        if process.stdout is not None:
            process.stdout.close()
    truncated = len(data) > ZSTD_MAX_DECOMPRESSED_BYTES
    if truncated:
        process.kill()
    try:
        process.wait(timeout=ZSTD_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        raise RuntimeError("zstd 解压超时")
    if process.returncode not in (0, -9) and not truncated:
        raise RuntimeError("zstd 解压失败（exit %d）" % process.returncode)
    if truncated:
        data = data[:ZSTD_MAX_DECOMPRESSED_BYTES]
    return data.decode("utf-8", "replace"), truncated


def _find_usage(event: dict) -> Optional[dict]:
    """事件里的用量：data.usage（真实形状），兼容顶层 usage。"""
    data = event.get("data")
    if isinstance(data, dict):
        usage = data.get("usage")
        if isinstance(usage, dict):
            return usage
    usage = event.get("usage")
    if isinstance(usage, dict):
        return usage
    return None


def collect_events(sessions_dir: Path, warnings: List[str]) -> Tuple[Dict[datetime.date, Dict[str, float]], int, bool, bool]:
    """返回 (按天 buckets, 用到的文件数, 是否有未识别 usage, 是否有 mtime 近似归日)。"""
    if not sessions_dir.is_dir():
        warnings.append("未找到 ~/.dsh/sessions 目录，跳过会话事件来源")
        return {}, 0, False, False

    try:
        files = sorted(
            sessions_dir.rglob("session.v4.jsonl.zstd"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
    except OSError as exc:
        warnings.append("读取 ~/.dsh/sessions 失败：%s" % exc)
        return {}, 0, False, False

    if not files:
        warnings.append("~/.dsh/sessions 下没有可用的会话日志")
        return {}, 0, False, False

    zstd_bin = _resolve_zstd()
    if zstd_bin is None:
        warnings.append("未找到 zstd，无法解压会话日志，跳过花费估算")
        return {}, 0, False, False

    if len(files) > SPEND_MAX_FILES:
        warnings.append("会话日志较多，花费估算只覆盖最近 %d 个" % SPEND_MAX_FILES)
        files = files[:SPEND_MAX_FILES]

    started = time.time()
    daily: Dict[datetime.date, Dict[str, float]] = {}
    used_files = 0
    skipped = 0
    saw_unrecognized = False
    approx_day = False
    truncated_files = 0

    for path in files:
        if time.time() - started > SPEND_SCAN_BUDGET_SECONDS:
            warnings.append("会话日志较多，花费估算只覆盖最近一部分")
            break
        try:
            text, truncated = _read_zstd_text(path, zstd_bin)
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            skipped += 1
            _log("跳过 %s：%s" % (path.name, exc))
            continue
        if truncated:
            truncated_files += 1

        file_used = False
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            usage = _find_usage(event)
            if usage is None:
                continue
            if not _has_any_usage_field(usage):
                saw_unrecognized = True
                continue
            day = _local_date_from_ms(event.get("time"))
            if day is None:
                day = _local_date_from_iso(event.get("timestamp")) or _local_date_from_iso(event.get("createdAt"))
            if day is None:
                day = _file_date(path)
                approx_day = True
            buckets = buckets_from_usage(usage)
            if _buckets_total(buckets) <= 0:
                continue
            bucket = daily.setdefault(day, {"miss": 0.0, "hit": 0.0, "out": 0.0})
            for key, value in buckets.items():
                bucket[key] += value
            file_used = True
        if file_used:
            used_files += 1

    if skipped:
        warnings.append("跳过 %d 个无法解压的会话日志" % skipped)
    if truncated_files:
        warnings.append("%d 个会话日志解压后过大，只统计了前 64MB" % truncated_files)
    if saw_unrecognized:
        warnings.append("会话日志有 usage 事件，但字段未识别（既不是 inputTokens 也不是 uncachedInputTokens 口径）")
    if approx_day:
        warnings.append("部分 usage 事件没有时间戳，已按文件修改时间归日（近似）")
    return daily, used_files, saw_unrecognized, approx_day


def collect_spend(
    projcache_dir: Path, sessions_dir: Path
) -> Tuple[Optional[dict], Optional[dict], List[str]]:
    """返回 (spend, coverage, warnings)。主源 projcache，次源会话事件。"""
    warnings: List[str] = []

    proj_sessions = collect_projcache(projcache_dir, warnings)
    daily: Dict[datetime.date, Dict[str, float]] = {}
    note = ""
    source = ""

    if proj_sessions:
        source = "projcache"
        for day, buckets in proj_sessions:
            bucket = daily.setdefault(day, {"miss": 0.0, "hit": 0.0, "out": 0.0})
            for key, value in buckets.items():
                bucket[key] += value
        note = "按会话聚合，日期为会话创建日期（本地时区），非官方账单"
    else:
        daily, used_files, _unrecognized, _approx = collect_events(sessions_dir, warnings)
        if daily:
            source = "events"
            note = "按事件时间逐日聚合（本地时区），本地日志覆盖，非官方账单"
        else:
            if not proj_sessions:
                warnings.append("本地没有可识别的 DeepSeek token 用量记录，无法估算花费")
            return None, None, warnings

    days = sorted(daily.keys())
    today = datetime.date.today()
    total = 0.0
    today_cost = 0.0
    for day in days:
        amount = estimate_cost(daily[day])
        total += amount
        if day == today:
            today_cost += amount

    warnings.append("花费按 token 与公开牌价估算（%s），非官方账单" % source)
    spend = {
        "today": round(today_cost, 4),
        "window": round(total, 4),
        "currency": DEFAULT_CURRENCY,
        "source": "estimate",
    }
    coverage = {
        "from": days[0].isoformat(),
        "to": days[-1].isoformat(),
        "note": note,
    }
    return spend, coverage, warnings


# ---------------------------------------------------------------- 输出


def _empty_payload() -> dict:
    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": utc_iso_now(),
        "observed_at": utc_iso_now(),
        "stale": False,
        "windows": [],
        "balance": None,
        "spend": None,
        "coverage": None,
        "warnings": [],
        "error": None,
    }


def build_payload() -> dict:
    warnings: List[str] = []

    balance, balance_warnings = fetch_balance(os.environ.get("DEEPSEEK_API_KEY"))
    warnings.extend(balance_warnings)

    spend, coverage, spend_warnings = collect_spend(PROJCACHE_DIR, SESSIONS_DIR)
    warnings.extend(spend_warnings)

    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": utc_iso_now(),
        "observed_at": utc_iso_now(),
        "stale": False,
        "windows": [],
        "balance": balance,
        "spend": spend,
        "coverage": coverage,
        "warnings": [redact(item) for item in warnings],
        "error": None,
    }


def emit(payload: dict) -> bool:
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
    except Exception as exc:  # 兜底：任何意外都给出 JSON
        payload = _empty_payload()
        payload["error"] = redact("生成 DeepSeek 用量失败：%s" % exc)

    if not emit(payload):
        return 1
    return 0 if payload["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
