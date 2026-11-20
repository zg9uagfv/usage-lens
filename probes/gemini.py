#!/usr/bin/env python3
"""usage-lens Gemini 探针。

账号门控：必须通过 GEMINI_ACCESS_TOKEN（及 GEMINI_ACCOUNT_EMAIL）提供 Gemini 账号后，
才查询 Google 官方 Cloud Code Assist 配额接口并输出 5 小时与 7 天使用量窗口。
未配置账号时零网络请求、零文件写入，退出码 0，windows 为空数组并给出中文引导。

只读，不落盘，不打印令牌；禁止跟随重定向（3xx 一律报错），严格绑定官方域名。
仅用标准库，兼容 Python 3.9+。
"""

from __future__ import annotations

import datetime
import json
import math
import os
import re
import sys
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest

SCHEMA = "usage-lens/probe@1"
PROVIDER = "gemini"

OFFICIAL_SCHEME = "https"
OFFICIAL_HOST = "cloudcode-pa.googleapis.com"
LOAD_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
RETRIEVE_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"

HTTP_TIMEOUT_SECONDS = 3.0
HTTP_MAX_BYTES = 1024 * 1024

ACCOUNT_REQUIRED_WARNING = "请先在配置中提供 Gemini 账号以查看 5 小时与 7 天用量"

WINDOW_SPEC = {
    "5h": {"id": "5h", "label": "5 小时", "window_seconds": 18000},
    "7d": {"id": "7d", "label": "7 天", "window_seconds": 604800},
}

_SECRET_PATTERNS = (
    re.compile(r"ya29\.[A-Za-z0-9._\-]+"),
    re.compile(r"1//[A-Za-z0-9._\-]{8,}"),
    re.compile(r"Bearer\s+\S+", re.IGNORECASE),
    re.compile(r"sk-[A-Za-z0-9_\-]{5,}"),
    re.compile(r"\b(?:api[_-]?key|key|token|secret|password)\b\s*[=:]\s*\S+", re.IGNORECASE),
    re.compile(r"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])"),
)

_ISO_DURATION_RE = re.compile(
    r"^P(?:(?P<days>\d+)D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?(?:(?P<seconds>\d+(?:\.\d+)?)S)?)?$",
    re.IGNORECASE,
)
_SUFFIX_DURATION_RE = re.compile(
    r"^(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$",
    re.IGNORECASE,
)


def redact(text: str) -> str:
    """把任何形似凭据的串抹掉，保证 warning / error / stderr 不泄露敏感信息。"""
    if not text:
        return text
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[redacted]", text)
    return text


def _log(message: str) -> None:
    sys.stderr.write("usage-lens/gemini: %s\n" % redact(message))


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def to_utc_iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_iso_now() -> str:
    return to_utc_iso(utc_now())


def parse_iso_epoch(text: Any) -> Optional[float]:
    """ISO8601 字符串 -> UTC epoch 秒；无法解析返回 None。"""
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    # Python 3.9 fromisoformat 不支持超过 6 位的小数秒（如纳秒），截断到微秒。
    frac_match = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d+)([+-]\d{2}:\d{2})?$", raw)
    if frac_match:
        prefix, frac, tz = frac_match.groups()
        frac = (frac[:6]).ljust(6, "0")
        raw = "%s.%s%s" % (prefix, frac, tz or "")
    try:
        moment = datetime.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.timestamp()


def epoch_to_iso(epoch_seconds: Optional[float]) -> Optional[str]:
    if epoch_seconds is None or not math.isfinite(epoch_seconds) or epoch_seconds <= 0:
        return None
    try:
        moment = datetime.datetime.fromtimestamp(epoch_seconds, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return to_utc_iso(moment)


def _as_finite_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return None
        try:
            number = float(stripped)
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(number):
        return None
    return number


def _human_age(seconds: float) -> str:
    if seconds >= 86400:
        return "%d 天前" % int(seconds // 86400)
    if seconds >= 3600:
        return "%d 小时前" % int(seconds // 3600)
    if seconds >= 60:
        return "%d 分钟前" % int(seconds // 60)
    return "刚刚"


# ---------------------------------------------------------------- 网络安全


class _RejectRedirect(urlrequest.HTTPRedirectHandler):
    """任何 3xx 一律不跟随：避免 Authorization 头被带到重定向目标。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urlrequest.build_opener(_RejectRedirect())


def is_official_url(url: str) -> bool:
    """只认 https + cloudcode-pa.googleapis.com（默认端口 443）。"""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if parts.scheme != OFFICIAL_SCHEME:
        return False
    if (parts.hostname or "").lower() != OFFICIAL_HOST:
        return False
    try:
        port = parts.port
    except ValueError:
        return False
    return port in (None, 443)


def _http_error_message(exc: urlerror.HTTPError) -> str:
    code = exc.code
    if code in (301, 302, 303, 307, 308):
        return "查询 Gemini 用量失败：接口返回重定向（HTTP %d），已按安全策略拒绝跟随" % code
    if code in (401, 403):
        return "Gemini 账号凭据无效或已过期（HTTP %d），请在配置中重新提供账号" % code
    if code == 429:
        return "查询 Gemini 用量失败：请求被限流（HTTP 429），请稍后重试"
    if 500 <= code < 600:
        return "查询 Gemini 用量失败：服务暂时不可用（HTTP %d），请稍后重试" % code
    return "查询 Gemini 用量失败：HTTP %d" % code


def _post_json(url: str, access_token: str, body_obj: dict) -> Tuple[Optional[dict], Optional[str]]:
    """向官方接口发送 JSON POST；任何错误都返回 (None, 中文脱敏错误信息)。"""
    raw_body = json.dumps(body_obj, ensure_ascii=False).encode("utf-8")
    request = urlrequest.Request(
        url,
        data=raw_body,
        headers={
            "Authorization": "Bearer " + access_token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with _OPENER.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            final_url = response.geturl()
            if not is_official_url(final_url):
                return None, "查询 Gemini 用量失败：响应最终地址不是官方域名，已拒绝使用"
            length = response.headers.get("Content-Length") if response.headers else None
            if length is not None:
                try:
                    if int(length) > HTTP_MAX_BYTES:
                        return None, "查询 Gemini 用量失败：响应体过大（%s 字节），已拒绝读取" % length
                except (TypeError, ValueError):
                    pass
            body = response.read(HTTP_MAX_BYTES + 1)
            if len(body) > HTTP_MAX_BYTES:
                return None, "查询 Gemini 用量失败：响应体超过 1MB 上限，已拒绝读取"
    except urlerror.HTTPError as exc:
        return None, redact(_http_error_message(exc))
    except urlerror.URLError as exc:
        return None, redact("查询 Gemini 用量失败：网络不可用（%s）" % exc.reason)
    except (TimeoutError, OSError) as exc:
        return None, redact("查询 Gemini 用量失败：请求超时或中断（%s）" % exc)
    except Exception as exc:
        return None, redact("查询 Gemini 用量失败：%s" % exc)

    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, "查询 Gemini 用量失败：接口返回不是合法 JSON"
    if not isinstance(data, dict):
        return None, "查询 Gemini 用量失败：接口返回格式异常"
    return data, None


# ---------------------------------------------------------------- 窗口归类与归一化


def _parse_duration_seconds(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        secs = float(value)
        return secs if math.isfinite(secs) and secs > 0 else None
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None

    iso_match = _ISO_DURATION_RE.match(text)
    if iso_match and any(iso_match.groups()):
        days = int(iso_match.group("days") or 0)
        hours = int(iso_match.group("hours") or 0)
        minutes = int(iso_match.group("minutes") or 0)
        seconds = float(iso_match.group("seconds") or 0.0)
        total = days * 86400 + hours * 3600 + minutes * 60 + seconds
        return total if total > 0 else None

    suffix_match = _SUFFIX_DURATION_RE.match(text)
    if suffix_match:
        val = float(suffix_match.group("value"))
        unit = suffix_match.group("unit").lower()
        if unit.startswith("d"):
            return val * 86400
        if unit.startswith("h"):
            return val * 3600
        if unit.startswith("m"):
            return val * 60
        return val

    plain = _as_finite_float(text)
    if plain is not None and plain > 0:
        return plain
    return None


def _classify_window(bucket: dict, resets_epoch: Optional[float], now_epoch: float) -> Optional[str]:
    for key in (
        "windowDuration",
        "quotaDuration",
        "duration",
        "period",
        "windowSeconds",
        "window_seconds",
        "window",
        "id",
    ):
        raw = bucket.get(key)
        if raw is None:
            continue
        if isinstance(raw, str):
            norm = raw.strip().lower()
            if norm in ("5h", "5 小时", "5小时"):
                return "5h"
            if norm in ("7d", "7 天", "7天"):
                return "7d"
        secs = _parse_duration_seconds(raw)
        if secs is not None:
            if 14400 <= secs <= 21600:
                return "5h"
            if 518400 <= secs <= 691200:
                return "7d"

    if resets_epoch is not None:
        delta = resets_epoch - now_epoch
        if delta <= 24 * 3600:
            return "5h"
        return "7d"

    return None


def _used_percent_from_bucket(bucket: dict, label: str, warnings: List[str]) -> Optional[float]:
    if "remainingFraction" in bucket and bucket["remainingFraction"] is not None:
        rem = _as_finite_float(bucket["remainingFraction"])
        if rem is None or rem < 0.0 or rem > 1.0:
            warnings.append("%s的 remainingFraction 数值异常，已置空" % label)
            return None
        return round((1.0 - rem) * 100.0, 2)

    for key in ("usedPercent", "used_percent"):
        if key in bucket and bucket[key] is not None:
            pct = _as_finite_float(bucket[key])
            if pct is None or pct < 0.0 or pct > 100.0:
                warnings.append("%s的 used_percent 数值异常，已置空" % label)
                return None
            return round(pct, 2)

    return None


def _extract_plan(load_data: dict) -> Optional[str]:
    tier = load_data.get("currentTier")
    if isinstance(tier, dict):
        for key in ("id", "name"):
            val = tier.get(key)
            if isinstance(val, str) and val.strip():
                return val.strip()
    elif isinstance(tier, str) and tier.strip():
        return tier.strip()
    return None


def _normalize_buckets(
    buckets: Any,
    now: datetime.datetime,
    warnings: List[str],
) -> List[dict]:
    if not isinstance(buckets, list):
        return []

    now_epoch = now.timestamp()
    grouped: Dict[str, List[dict]] = {"5h": [], "7d": []}

    for item in buckets:
        if not isinstance(item, dict):
            continue
        resets_epoch = parse_iso_epoch(item.get("resetTime") or item.get("resets_at"))
        window_id = _classify_window(item, resets_epoch, now_epoch)
        if window_id not in grouped:
            continue
        spec = WINDOW_SPEC[window_id]
        used_percent = _used_percent_from_bucket(item, spec["label"], warnings)
        grouped[window_id].append(
            {
                "used_percent": used_percent,
                "resets_epoch": resets_epoch,
                "resets_at": epoch_to_iso(resets_epoch),
            }
        )

    windows: List[dict] = []
    for window_id in ("5h", "7d"):
        candidates = grouped[window_id]
        if not candidates:
            continue
        spec = WINDOW_SPEC[window_id]
        # 保守聚合：取已用百分比最高的桶；同百分比取最早重置时间；全为 None 时取最早重置时间。
        valid = [c for c in candidates if c["used_percent"] is not None]
        if valid:
            chosen = max(
                valid,
                key=lambda c: (
                    c["used_percent"],
                    -(c["resets_epoch"] if c["resets_epoch"] is not None else float("inf")),
                ),
            )
        else:
            chosen = min(
                candidates,
                key=lambda c: c["resets_epoch"] if c["resets_epoch"] is not None else float("inf"),
            )

        resets_epoch = chosen["resets_epoch"]
        expired = False
        if resets_epoch is not None and resets_epoch < now_epoch:
            expired = True
            warnings.append(
                "%s窗口已于 %s重置" % (spec["label"], _human_age(now_epoch - resets_epoch))
            )

        windows.append(
            {
                "id": spec["id"],
                "label": spec["label"],
                "used_percent": chosen["used_percent"],
                "window_seconds": spec["window_seconds"],
                "resets_at": chosen["resets_at"],
                "expired": expired,
                "basis": "server",
            }
        )

    if not windows:
        warnings.append("Gemini 接口未返回 5 小时或 7 天配额窗口")
    else:
        present = {w["id"] for w in windows}
        if "5h" not in present:
            warnings.append("Gemini 接口未返回 5 小时配额窗口")
        if "7d" not in present:
            warnings.append("Gemini 接口未返回 7 天配额窗口")

    return windows


# ---------------------------------------------------------------- 主流程


def _empty_payload(now_iso: Optional[str] = None) -> dict:
    stamp = now_iso or utc_iso_now()
    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": None, "plan": None},
        "generated_at": stamp,
        "observed_at": stamp,
        "stale": False,
        "windows": [],
        "balance": None,
        "spend": None,
        "usage": None,
        "coverage": None,
        "warnings": [],
        "error": None,
    }


def _dedupe_redacted(items: List[str]) -> List[str]:
    seen = set()
    result: List[str] = []
    for item in items:
        cleaned = redact(item)
        if cleaned not in seen:
            seen.add(cleaned)
            result.append(cleaned)
    return result


def build_payload() -> dict:
    now = utc_now()
    now_iso = to_utc_iso(now)

    email = (os.environ.get("GEMINI_ACCOUNT_EMAIL") or "").strip()
    access_token = (os.environ.get("GEMINI_ACCESS_TOKEN") or "").strip()
    project_id = (os.environ.get("GEMINI_PROJECT_ID") or "").strip()

    # 账号门控：未提供访问令牌时零网络请求，直接返回引导文案。
    if not access_token:
        payload = _empty_payload(now_iso)
        payload["warnings"] = [ACCOUNT_REQUIRED_WARNING]
        return payload

    plan: Optional[str] = None
    if not project_id:
        load_data, load_err = _post_json(
            LOAD_CODE_ASSIST_URL,
            access_token,
            {"metadata": {"ideType": "GEMINI_CLI", "platform": "MACOS"}},
        )
        if load_err is not None:
            payload = _empty_payload(now_iso)
            payload["account"] = {"label": email or None, "plan": None}
            payload["error"] = redact(load_err)
            return payload
        assert load_data is not None
        raw_project = load_data.get("cloudaicompanionProject")
        if isinstance(raw_project, str) and raw_project.strip():
            project_id = raw_project.strip()
        plan = _extract_plan(load_data)

    quota_req = {"project": project_id} if project_id else {}
    quota_data, quota_err = _post_json(RETRIEVE_QUOTA_URL, access_token, quota_req)
    if quota_err is not None:
        payload = _empty_payload(now_iso)
        payload["account"] = {"label": email or None, "plan": plan}
        payload["error"] = redact(quota_err)
        return payload

    assert quota_data is not None
    warnings: List[str] = []
    windows = _normalize_buckets(quota_data.get("buckets"), now, warnings)

    return {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": email or None, "plan": plan},
        "generated_at": now_iso,
        "observed_at": now_iso,
        "stale": False,
        "windows": windows,
        "balance": None,
        "spend": None,
        "usage": None,
        "coverage": None,
        "warnings": _dedupe_redacted(warnings),
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
            payload["error"] = redact("不支持的参数：%s（只接受无参数或 --json）" % arg)
            emit(payload)
            _log(payload["error"])
            return 2

    try:
        payload = build_payload()
    except Exception as exc:
        payload = _empty_payload()
        payload["error"] = redact("读取 Gemini 用量失败：%s" % exc)

    if not emit(payload):
        return 1
    return 0 if payload["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
