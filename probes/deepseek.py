#!/usr/bin/env python3
"""usage-lens DeepSeek 探针。

DeepSeek 没有窗口配额，所以 windows 恒为空数组——不编百分比。
能拿到的只有两样：
  1. 余额：$DEEPSEEK_API_KEY 存在时请求官方 GET /user/balance（3s 超时）
  2. 花费估算：解压 ~/.dsh/sessions/**/session.v4.jsonl.zstd 里的 tokenUsage.totals

只读，不落盘，不打印 key。仅用标准库，兼容 Python 3.9。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest

SCHEMA = "usage-lens/probe@1"
PROVIDER = "deepseek"

BALANCE_URL = "https://api.deepseek.com/user/balance"
BALANCE_TIMEOUT_SECONDS = 3.0

DSH_SESSIONS_DIR = Path.home() / ".dsh" / "sessions"
ZSTD_BIN = "/opt/homebrew/bin/zstd"
ZSTD_TIMEOUT_SECONDS = 10
SPEND_SCAN_BUDGET_SECONDS = 3.0
SPEND_MAX_FILES = 500

# 只在 totals 里没有明确费用字段时才用这张牌价折算。
# 来源：DeepSeek 公开牌价（deepseek-chat），单位 CNY / 百万 tokens。牌价会变，仅作估算。
PRICE_PER_MILLION_TOKENS_CNY = {
    "input_cache_miss": 2.0,
    "input_cache_hit": 0.2,
    "output": 3.0,
}
DEFAULT_CURRENCY = "CNY"


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/deepseek: %s\n" % message)


_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{6,}"),
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
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


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
        with urlrequest.urlopen(request, timeout=BALANCE_TIMEOUT_SECONDS) as response:
            body = response.read()
    except urlerror.HTTPError as exc:
        return None, ["查询 DeepSeek 余额失败：HTTP %s" % exc.code]
    except urlerror.URLError as exc:
        return None, ["查询 DeepSeek 余额失败：网络不可用（%s）" % exc.reason]
    except (TimeoutError, OSError) as exc:
        return None, ["查询 DeepSeek 余额失败：请求超时或中断（%s）" % exc]
    except Exception as exc:  # 兜底，绝不把异常抛给 App
        return None, ["查询 DeepSeek 余额失败：%s" % exc]

    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, ["查询 DeepSeek 余额失败：返回不是合法 JSON"]

    infos = data.get("balance_infos") if isinstance(data, dict) else None
    if not isinstance(infos, list) or not infos:
        return None, ["DeepSeek 余额接口没有返回余额明细"]

    first = infos[0]
    if not isinstance(first, dict):
        return None, ["DeepSeek 余额接口返回的明细格式不对"]

    amount = _as_float(first.get("total_balance"))
    if amount is None:
        return None, ["DeepSeek 余额接口没有可读的余额数字"]

    currency = first.get("currency")
    if not isinstance(currency, str) or not currency:
        currency = DEFAULT_CURRENCY

    return {"amount": round(amount, 2), "currency": currency, "source": "official"}, []


def _find_totals(node: Any) -> Optional[dict]:
    """在一条事件里找 tokenUsage.totals（容忍 token_usage / data 包裹）。"""
    if isinstance(node, dict):
        for key in ("tokenUsage", "token_usage"):
            usage = node.get(key)
            if isinstance(usage, dict):
                totals = usage.get("totals")
                if isinstance(totals, dict):
                    return totals
    return None


def _event_day(event: dict, path: Path) -> Optional[datetime.date]:
    for key in ("time", "timestamp", "createdAt", "created_at"):
        value = event.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            seconds = float(value)
            if seconds > 1e11:  # 毫秒
                seconds /= 1000.0
            try:
                return datetime.datetime.fromtimestamp(seconds).date()
            except (OverflowError, OSError, ValueError):
                continue
        if isinstance(value, str):
            text = value.replace("Z", "+00:00")
            try:
                return datetime.datetime.fromisoformat(text).astimezone().date()
            except ValueError:
                continue
    try:
        return datetime.datetime.fromtimestamp(path.stat().st_mtime).date()
    except OSError:
        return None


def _totals_to_usage(totals: dict) -> Tuple[Dict[str, float], Optional[float], Optional[str]]:
    """把 totals 拆成 (token 桶, 显式费用, 币种)。"""
    tokens: Dict[str, float] = {}
    cost: Optional[float] = None
    currency: Optional[str] = None

    for raw_key, raw_value in totals.items():
        key = str(raw_key).lower().replace("_", "").replace("-", "")
        value = _as_float(raw_value)
        if value is None:
            if key in ("currency",) and isinstance(raw_value, str) and raw_value:
                currency = raw_value
            continue
        if key == "currency":
            continue
        if "cost" in key or "spend" in key or key in ("amount", "totalamount"):
            cost = (cost or 0.0) + value
        elif key.endswith("tokens") or key == "tokens":
            tokens[key] = tokens.get(key, 0.0) + value
    return tokens, cost, currency


def estimate_cost(tokens: Dict[str, float]) -> float:
    """用公开牌价把 token 折算成 CNY 估算值。没有 token 时返回 0。"""
    price = PRICE_PER_MILLION_TOKENS_CNY

    def pick(*names: str) -> float:
        for name in names:
            if name in tokens:
                return tokens[name]
        return 0.0

    input_tokens = pick("inputtokens")
    cached_input = pick("cachedinputtokens", "cachehittokens", "cachedtokens")
    output_tokens = pick("outputtokens")
    total_tokens = pick("totaltokens")

    # totals 可能只给 total，那就按「一半输入一半输出」粗折，宁可保守。
    if not input_tokens and not output_tokens and total_tokens:
        input_tokens = total_tokens / 2.0
        output_tokens = total_tokens / 2.0

    uncached_input = max(input_tokens - cached_input, 0.0)
    cost = (
        uncached_input * price["input_cache_miss"]
        + cached_input * price["input_cache_hit"]
        + output_tokens * price["output"]
    ) / 1_000_000.0
    return cost


def _resolve_zstd() -> Optional[str]:
    if os.path.isfile(ZSTD_BIN) and os.access(ZSTD_BIN, os.X_OK):
        return ZSTD_BIN
    found = shutil.which("zstd")
    return found


def _read_zstd_lines(path: Path, zstd_bin: str) -> List[str]:
    completed = subprocess.run(
        [zstd_bin, "-dc", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=ZSTD_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError("zstd 解压失败（exit %d）" % completed.returncode)
    return completed.stdout.decode("utf-8", "replace").splitlines()


def collect_spend(sessions_dir: Path) -> Tuple[Optional[dict], Optional[dict], List[str]]:
    """返回 (spend, coverage, warnings)。"""
    warnings: List[str] = []

    if not sessions_dir.is_dir():
        return None, None, ["未找到 ~/.dsh/sessions 目录，跳过花费估算"]

    try:
        files = sorted(
            sessions_dir.rglob("session.v4.jsonl.zstd"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
    except OSError as exc:
        return None, None, ["读取 ~/.dsh/sessions 失败：%s" % exc]

    if not files:
        return None, None, ["~/.dsh/sessions 下没有可用的 DeepSeek 会话日志"]

    zstd_bin = _resolve_zstd()
    if zstd_bin is None:
        return None, None, ["未找到 zstd，无法解压 DeepSeek 会话日志，跳过花费估算"]

    started = time.time()
    daily_tokens: Dict[datetime.date, Dict[str, float]] = {}
    daily_cost: Dict[datetime.date, float] = {}
    currency: Optional[str] = None
    used_files = 0
    skipped = 0

    for path in files[:SPEND_MAX_FILES]:
        if time.time() - started > SPEND_SCAN_BUDGET_SECONDS:
            warnings.append("DeepSeek 会话日志较多，花费估算只覆盖最近一部分")
            break
        try:
            lines = _read_zstd_lines(path, zstd_bin)
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            skipped += 1
            _log("跳过 %s：%s" % (path.name, exc))
            continue

        file_had_totals = False
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            totals = _find_totals(event)
            if totals is None:
                continue
            day = _event_day(event, path)
            if day is None:
                continue
            file_had_totals = True
            tokens, cost, event_currency = _totals_to_usage(totals)
            bucket = daily_tokens.setdefault(day, {})
            for key, value in tokens.items():
                bucket[key] = bucket.get(key, 0.0) + value
            if cost is not None:
                daily_cost[day] = daily_cost.get(day, 0.0) + cost
                if event_currency:
                    currency = event_currency
        if file_had_totals:
            used_files += 1

    if skipped:
        warnings.append("跳过 %d 个无法解压的会话日志" % skipped)

    if not used_files:
        return None, None, warnings + ["DeepSeek 会话日志里没有 token 用量记录，无法估算花费"]

    days = sorted(daily_tokens.keys())
    total = 0.0
    today = datetime.date.today()
    today_cost = 0.0
    used_prices = False
    for day in days:
        if day in daily_cost:
            amount = daily_cost[day]
        else:
            amount = estimate_cost(daily_tokens[day])
            used_prices = True
        total += amount
        if day == today:
            today_cost += amount

    if used_prices:
        warnings.append("花费按本地 token 与公开牌价估算，非官方账单")

    spend = {
        "today": round(today_cost, 4),
        "window": round(total, 4),
        "currency": currency or DEFAULT_CURRENCY,
        "source": "estimate",
    }
    coverage = {
        "from": days[0].isoformat(),
        "to": days[-1].isoformat(),
        "note": "本地日志覆盖，非官方账单",
    }
    return spend, coverage, warnings


def build_payload() -> dict:
    warnings: List[str] = []

    balance, balance_warnings = fetch_balance(os.environ.get("DEEPSEEK_API_KEY"))
    warnings.extend(balance_warnings)

    spend, coverage, spend_warnings = collect_spend(DSH_SESSIONS_DIR)
    warnings.extend(spend_warnings)

    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": utc_iso_now(),
        "windows": [],
        "balance": balance,
        "spend": spend,
        "coverage": coverage,
        "warnings": [redact(item) for item in warnings],
        "error": None,
    }


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _empty_payload() -> dict:
    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": utc_iso_now(),
        "windows": [],
        "balance": None,
        "spend": None,
        "coverage": None,
        "warnings": [],
        "error": None,
    }


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
        emit(payload)
        _log(payload["error"])
        return 1

    emit(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
