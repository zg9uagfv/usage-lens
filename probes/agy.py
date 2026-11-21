#!/usr/bin/env python3
"""usage-lens AGY (Antigravity) 探针。

自动只读复用本机 AGY 登录态（macOS 钥匙串 service="gemini", account="antigravity"，
go-keyring-base64: 编码载荷；或测试用环境变量 / 本地文件覆盖），实时查询官方服务端
https://daily-cloudcode-pa.googleapis.com（loadCodeAssist + retrieveUserQuotaSummary +
retrieveUserQuota），并按保守最大原则归一化为标准 5h / 7d 窗口。
同时只读尾扫本机 AGY 会话日志统计「今日 tokens」。

只读，不落盘，不修改钥匙串，不打印令牌；禁止跟随重定向（3xx 一律拒绝），严格绑定官方域名。
仅用标准库，兼容 Python 3.9+。
"""

from __future__ import annotations

import base64
import datetime
import json
import math
import os
import pwd
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest

SCHEMA = "usage-lens/probe@1"
PROVIDER = "agy"

OFFICIAL_SCHEME = "https"
OFFICIAL_HOST = "daily-cloudcode-pa.googleapis.com"
LOAD_CODE_ASSIST_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
RETRIEVE_QUOTA_SUMMARY_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
RETRIEVE_QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"

OAUTH_TOKEN_HOST = "oauth2.googleapis.com"
OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
PROACTIVE_REFRESH_SKEW_SECONDS = 60.0

HTTP_TIMEOUT_SECONDS = 3.0
HTTP_MAX_BYTES = 1024 * 1024

KEYCHAIN_TIMEOUT_SECONDS = 2.0
KEYCHAIN_SERVICE = "gemini"
KEYCHAIN_ACCOUNT = "antigravity"
GO_KEYRING_B64_PREFIX = "go-keyring-base64:"

TAIL_CHUNK_BYTES = 256 * 1024
MAX_SCAN_BYTES = 4 * 1024 * 1024
TODAY_TOKEN_SCAN_FILES = 50

LOCAL_AUTH_FILE: Optional[Path] = None
BRAIN_DIRS: Optional[List[Path]] = None

AUTH_REQUIRED_WARNING = "未检测到本机 AGY 登录态，请先运行 agy 登录以查看 5 小时与 7 天用量"

WINDOW_SPEC = {
    "5h": {"id": "5h", "label": "5 小时", "window_seconds": 18000},
    "7d": {"id": "7d", "label": "7 天", "window_seconds": 604800},
}

_SECRET_PATTERNS = (
    re.compile(r"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"),
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
    sys.stderr.write("usage-lens/agy: %s\n" % redact(message))


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def to_utc_iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_iso_now() -> str:
    return to_utc_iso(utc_now())


def parse_iso_epoch(text: Any) -> Optional[float]:
    """ISO8601 / RFC3339 字符串 -> UTC epoch 秒；无法解析返回 None。"""
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    frac_match = re.match(
        r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d+)([+-]\d{2}:\d{2})?$",
        raw,
    )
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
    """任何 3xx 一律不跟随：避免 Authorization / refresh_token 被带到重定向目标。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urlrequest.build_opener(_RejectRedirect())


def _is_pinned_https_url(url: str, expected_host: str) -> bool:
    if not isinstance(url, str) or not url:
        return False
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if parts.scheme != OFFICIAL_SCHEME:
        return False
    if parts.username is not None or parts.password is not None:
        return False
    if (parts.hostname or "").lower() != expected_host:
        return False
    try:
        port = parts.port
    except ValueError:
        return False
    return port in (None, 443)


def is_official_url(url: str) -> bool:
    """只认 https + daily-cloudcode-pa.googleapis.com（默认端口 443，无 userinfo）。"""
    return _is_pinned_https_url(url, OFFICIAL_HOST)


def is_official_oauth_url(url: str) -> bool:
    """只认 https + oauth2.googleapis.com（默认端口 443，无 userinfo）。"""
    return _is_pinned_https_url(url, OAUTH_TOKEN_HOST)


def _http_error_reason(exc: urlerror.HTTPError, source: str = "local") -> str:
    code = exc.code
    if code in (301, 302, 303, 307, 308):
        return "接口返回重定向（HTTP %d），已按安全策略拒绝跟随" % code
    if code in (401, 403):
        if source == "local":
            return "本机 AGY 登录态无效或已过期（HTTP %d），请先运行 agy 刷新登录态" % code
        return "AGY 凭据无效或已过期（HTTP %d）" % code
    if code == 429:
        return "请求被限流（HTTP 429），请稍后重试"
    if 500 <= code < 600:
        return "服务暂时不可用（HTTP %d），请稍后重试" % code
    return "HTTP %d" % code


def _post_json_with_status(
    url: str,
    access_token: str,
    body_obj: dict,
    source: str = "local",
) -> Tuple[Optional[dict], Optional[str], Optional[int]]:
    """向 AGY 官方接口发送 JSON POST；返回 (data, 脱敏中文原因, HTTP 状态码)。"""
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
                return None, "响应最终地址不是官方域名，已拒绝使用", None
            length = response.headers.get("Content-Length") if response.headers else None
            if length is not None:
                try:
                    if int(length) > HTTP_MAX_BYTES:
                        return None, "响应体过大（%s 字节），已拒绝读取" % length, None
                except (TypeError, ValueError):
                    pass
            body = response.read(HTTP_MAX_BYTES + 1)
            if len(body) > HTTP_MAX_BYTES:
                return None, "响应体超过 1MB 上限，已拒绝读取", None
    except urlerror.HTTPError as exc:
        return None, redact(_http_error_reason(exc, source=source)), exc.code
    except urlerror.URLError as exc:
        return None, redact("网络不可用（%s）" % exc.reason), None
    except (TimeoutError, OSError) as exc:
        return None, redact("请求超时或中断（%s）" % exc), None
    except Exception as exc:
        return None, redact(str(exc)), None

    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, "接口返回不是合法 JSON", None
    if not isinstance(data, dict):
        return None, "接口返回格式异常", None
    return data, None, 200


# ---------------------------------------------------------------- 凭据发现与内存刷新


def _decode_jwt_payload(token: Any) -> Optional[dict]:
    """只读解码 JWT payload（仅提取非敏感 email，绝不打印或落盘令牌）。"""
    if not isinstance(token, str):
        return None
    parts = token.split(".")
    if len(parts) < 2 or not parts[1]:
        return None
    segment = parts[1]
    padding = "=" * (-len(segment) % 4)
    try:
        raw = base64.urlsafe_b64decode((segment + padding).encode("ascii"))
        claims = json.loads(raw.decode("utf-8"))
    except (ValueError, TypeError, UnicodeDecodeError):
        return None
    return claims if isinstance(claims, dict) else None


def _parse_expiry_epoch(value: Any) -> Optional[float]:
    if isinstance(value, str):
        parsed = parse_iso_epoch(value)
        if parsed is not None:
            return parsed
    num = _as_finite_float(value)
    if num is None or num <= 0:
        return None
    if num > 1e11:
        return num / 1000.0
    return num


def _decode_keyring_payload(raw: str) -> Optional[dict]:
    """解码 go-keyring-base64: 载荷或纯 JSON 载荷，返回规范化凭据字典。"""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text:
        return None

    if text.startswith(GO_KEYRING_B64_PREFIX):
        encoded = text[len(GO_KEYRING_B64_PREFIX):].strip()
        try:
            decoded_bytes = base64.b64decode(encoded)
            data = json.loads(decoded_bytes.decode("utf-8"))
        except (ValueError, TypeError, UnicodeDecodeError):
            return None
    else:
        try:
            data = json.loads(text)
        except ValueError:
            return None

    if not isinstance(data, dict):
        return None

    token_obj = data.get("token")
    if not isinstance(token_obj, dict):
        token_obj = data

    raw_access = token_obj.get("access_token")
    access_token = raw_access.strip() if isinstance(raw_access, str) and raw_access.strip() else None

    raw_refresh = token_obj.get("refresh_token")
    refresh_token = raw_refresh.strip() if isinstance(raw_refresh, str) and raw_refresh.strip() else None

    if not access_token and not refresh_token:
        return None

    expiry_epoch = _parse_expiry_epoch(
        token_obj.get("expiry") if token_obj.get("expiry") is not None else token_obj.get("expiry_date")
    )

    email: Optional[str] = None
    raw_email = data.get("id_token_email") or data.get("email")
    if isinstance(raw_email, str) and raw_email.strip():
        email = raw_email.strip()
    else:
        claims = _decode_jwt_payload(token_obj.get("id_token") or data.get("id_token"))
        if claims is not None:
            claim_email = claims.get("email")
            if isinstance(claim_email, str) and claim_email.strip():
                email = claim_email.strip()

    raw_client_id = data.get("client_id") or token_obj.get("client_id")
    client_id = (
        raw_client_id.strip()
        if isinstance(raw_client_id, str) and raw_client_id.strip()
        else ((os.environ.get("AGY_OAUTH_CLIENT_ID") or "").strip() or None)
    )

    raw_client_secret = data.get("client_secret") or token_obj.get("client_secret")
    client_secret = (
        raw_client_secret.strip()
        if isinstance(raw_client_secret, str) and raw_client_secret.strip()
        else ((os.environ.get("AGY_OAUTH_CLIENT_SECRET") or "").strip() or None)
    )

    return {
        "source": "local",
        "email": email,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expiry_epoch": expiry_epoch,
        "client_id": client_id,
        "client_secret": client_secret,
        "project_id": None,
    }


def _is_home_isolated() -> bool:
    """判断当前 HOME 是否与系统用户真实主目录不同（隔离测试环境自动跳过真实钥匙串）。"""
    try:
        real_pw_home = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        return True
    current_home = os.path.realpath(str(Path.home()))
    return current_home != real_pw_home


def _local_auth_file_path() -> Path:
    if LOCAL_AUTH_FILE is not None:
        return LOCAL_AUTH_FILE
    env_path = (os.environ.get("AGY_AUTH_FILE") or "").strip()
    if env_path:
        return Path(env_path)
    return Path.home() / ".gemini" / "antigravity-cli" / "auth.json"


def _load_keychain_credentials() -> Optional[dict]:
    """只读读取 macOS 登录钥匙串中的 AGY go-keyring 凭据。"""
    if sys.platform != "darwin":
        return None
    if _is_home_isolated():
        return None
    try:
        completed = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=KEYCHAIN_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    raw = (completed.stdout or "").strip()
    if not raw:
        return None
    return _decode_keyring_payload(raw)


def _resolve_credentials() -> Optional[dict]:
    """只读解析 AGY 凭据：AGY_ACCESS_TOKEN > DISABLE 门控 > 本地 auth.json > macOS 钥匙串。"""
    env_token = (os.environ.get("AGY_ACCESS_TOKEN") or "").strip()
    env_email = (os.environ.get("AGY_ACCOUNT_EMAIL") or "").strip() or None
    env_project = (os.environ.get("AGY_PROJECT_ID") or "").strip() or None

    if env_token:
        return {
            "source": "manual",
            "email": env_email,
            "access_token": env_token,
            "refresh_token": None,
            "expiry_epoch": None,
            "client_id": None,
            "client_secret": None,
            "project_id": env_project,
        }

    if (os.environ.get("AGY_DISABLE_LOCAL_AUTH") or "").strip() == "1":
        return None

    local: Optional[dict] = None
    auth_path = _local_auth_file_path()
    if auth_path.is_file():
        try:
            raw = auth_path.read_text(encoding="utf-8")
            local = _decode_keyring_payload(raw)
        except (OSError, UnicodeDecodeError):
            local = None

    if local is None:
        local = _load_keychain_credentials()

    if local is None:
        return None

    local["email"] = env_email or local["email"]
    local["project_id"] = env_project
    return local


def _refresh_access_token(creds: dict) -> Tuple[Optional[str], Optional[str]]:
    """仅在内存中通过官方 https://oauth2.googleapis.com/token 刷新 access_token（零写盘、零写钥匙串）。"""
    refresh_token = creds.get("refresh_token")
    client_id = creds.get("client_id")
    if not refresh_token or not client_id:
        return None, "本机 AGY 登录态已过期，请先运行 agy 刷新登录态"

    form_fields = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }
    if creds.get("client_secret"):
        form_fields["client_secret"] = creds["client_secret"]

    raw_body = urllib.parse.urlencode(form_fields).encode("utf-8")
    request = urlrequest.Request(
        OAUTH_TOKEN_URL,
        data=raw_body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with _OPENER.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            final_url = response.geturl()
            if not is_official_oauth_url(final_url):
                return None, "刷新本机 AGY 登录态失败：响应最终地址不是官方域名，已拒绝使用"
            length = response.headers.get("Content-Length") if response.headers else None
            if length is not None:
                try:
                    if int(length) > HTTP_MAX_BYTES:
                        return None, "刷新本机 AGY 登录态失败：响应体过大（%s 字节），已拒绝读取" % length
                except (TypeError, ValueError):
                    pass
            body = response.read(HTTP_MAX_BYTES + 1)
            if len(body) > HTTP_MAX_BYTES:
                return None, "刷新本机 AGY 登录态失败：响应体超过 1MB 上限，已拒绝读取"
    except urlerror.HTTPError as exc:
        code = exc.code
        if code in (301, 302, 303, 307, 308):
            return None, "刷新本机 AGY 登录态失败：接口返回重定向（HTTP %d），已按安全策略拒绝跟随" % code
        if code in (400, 401, 403):
            return None, "本机 AGY 登录态已过期或刷新失败（HTTP %d），请先运行 agy 刷新登录态" % code
        if code == 429:
            return None, "刷新本机 AGY 登录态失败：请求被限流（HTTP 429），请稍后重试"
        if 500 <= code < 600:
            return None, "刷新本机 AGY 登录态失败：服务暂时不可用（HTTP %d），请稍后重试" % code
        return None, "刷新本机 AGY 登录态失败：HTTP %d" % code
    except urlerror.URLError as exc:
        return None, redact("刷新本机 AGY 登录态失败：网络不可用（%s）" % exc.reason)
    except (TimeoutError, OSError) as exc:
        return None, redact("刷新本机 AGY 登录态失败：请求超时或中断（%s）" % exc)
    except Exception as exc:
        return None, redact("刷新本机 AGY 登录态失败：%s" % exc)

    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, "刷新本机 AGY 登录态失败：接口返回不是合法 JSON"
    if not isinstance(data, dict):
        return None, "刷新本机 AGY 登录态失败：接口返回格式异常"
    raw_token = data.get("access_token")
    if not isinstance(raw_token, str) or not raw_token.strip():
        return None, "刷新本机 AGY 登录态失败：接口未返回有效访问令牌"
    return raw_token.strip(), None


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
        "window",
        "bucketId",
        "windowDuration",
        "quotaDuration",
        "duration",
        "period",
        "windowSeconds",
        "window_seconds",
        "id",
    ):
        raw = bucket.get(key)
        if raw is None:
            continue
        if isinstance(raw, str):
            norm = raw.strip().lower()
            if (
                norm in ("5h", "five_hour", "5 小时", "5小时")
                or norm.endswith("-5h")
                or norm.endswith("_5h")
            ):
                return "5h"
            if (
                norm in ("weekly", "7d", "7 天", "7天")
                or norm.endswith("-weekly")
                or norm.endswith("_weekly")
                or norm.endswith("-7d")
                or norm.endswith("_7d")
            ):
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
    for tier_key in ("paidTier", "currentTier"):
        tier = load_data.get(tier_key)
        if isinstance(tier, dict):
            for field in ("name", "id"):
                val = tier.get(field)
                if isinstance(val, str) and val.strip():
                    return val.strip()
        elif isinstance(tier, str) and tier.strip():
            return tier.strip()
    return None


def _collect_buckets(summary_data: Optional[dict], quota_data: Optional[dict]) -> List[dict]:
    collected: List[dict] = []
    if isinstance(summary_data, dict):
        groups = summary_data.get("groups")
        if isinstance(groups, list):
            for group in groups:
                if not isinstance(group, dict):
                    continue
                buckets = group.get("buckets")
                if isinstance(buckets, list):
                    for bucket in buckets:
                        if isinstance(bucket, dict):
                            collected.append(bucket)
    if isinstance(quota_data, dict):
        buckets = quota_data.get("buckets")
        if isinstance(buckets, list):
            for bucket in buckets:
                if isinstance(bucket, dict):
                    collected.append(bucket)
    return collected


def _normalize_buckets(
    buckets: List[dict],
    now: datetime.datetime,
    warnings: List[str],
) -> List[dict]:
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
        warnings.append("AGY 接口未返回 5 小时或 7 天配额窗口")
    else:
        present = {w["id"] for w in windows}
        if "5h" not in present:
            warnings.append("AGY 接口未返回 5 小时配额窗口")
        if "7d" not in present:
            warnings.append("AGY 接口未返回 7 天配额窗口")

    return windows


# ---------------------------------------------------------------- 本地今日 tokens 统计


def _brain_dirs() -> List[Path]:
    if BRAIN_DIRS is not None:
        return list(BRAIN_DIRS)
    home = Path.home()
    return [
        home / ".gemini" / "antigravity-cli" / "brain",
        home / ".gemini" / "antigravity" / "brain",
    ]


def _iter_lines_reverse(path: Path) -> Iterator[bytes]:
    """从文件末尾往前按块读，逐行倒序产出，跳过空行，最多扫 MAX_SCAN_BYTES。"""
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
        if position == 0 and buffered.strip():
            yield buffered


def _non_negative_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number) or number < 0:
        return None
    return int(number)


def _today_token_record(raw: bytes, today: datetime.date) -> Optional[int]:
    """解析一行 AGY transcript.jsonl 的 PLANNER_RESPONSE token 用量。"""
    try:
        record = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(record, dict):
        return None
    if record.get("type") != "PLANNER_RESPONSE":
        return None

    epoch = parse_iso_epoch(record.get("created_at"))
    if epoch is None:
        return None
    if datetime.datetime.fromtimestamp(epoch).date() != today:
        return None

    subtotal = 0
    has_token_field = False
    for key in ("input_tokens", "output_tokens", "cache_read_tokens"):
        val = _non_negative_int(record.get(key))
        if val is not None:
            subtotal += val
            has_token_field = True
    return subtotal if has_token_field else None


def find_today_tokens(
    today: datetime.date,
    brain_dirs: Optional[List[Path]] = None,
) -> Tuple[Optional[int], List[str]]:
    """只读尾扫本地 AGY transcript.jsonl，统计当天 token 用量；无记录时返回 None。"""
    dirs = brain_dirs if brain_dirs is not None else _brain_dirs()
    candidates: List[Tuple[float, Path]] = []
    seen_paths = set()

    for base in dirs:
        if not base.is_dir():
            continue
        try:
            for path in base.glob("*/.system_generated/logs/transcript.jsonl"):
                if not path.is_file():
                    continue
                resolved = os.path.realpath(str(path))
                if resolved in seen_paths:
                    continue
                seen_paths.add(resolved)
                try:
                    candidates.append((path.stat().st_mtime, path))
                except OSError:
                    continue
        except OSError:
            continue

    if not candidates:
        return None, []

    candidates.sort(key=lambda item: item[0], reverse=True)
    candidates = candidates[:TODAY_TOKEN_SCAN_FILES]

    total = 0
    found = False
    truncated = 0
    for mtime, path in candidates:
        try:
            if datetime.datetime.fromtimestamp(mtime).date() < today:
                break
            for raw in _iter_lines_reverse(path):
                value = _today_token_record(raw, today)
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
        if cleaned and cleaned not in seen:
            seen.add(cleaned)
            result.append(cleaned)
    return result


def build_payload() -> dict:
    started = time.time()
    now = utc_now()
    now_iso = to_utc_iso(now)

    today_tokens, token_warnings = find_today_tokens(now.date())
    usage_obj = (
        {"today_tokens": today_tokens, "source": "local"}
        if today_tokens is not None
        else None
    )

    creds = _resolve_credentials()
    if creds is None:
        payload = _empty_payload(now_iso)
        payload["usage"] = usage_obj
        payload["warnings"] = _dedupe_redacted([AUTH_REQUIRED_WARNING] + token_warnings)
        return payload

    source = creds["source"]
    email = creds.get("email")
    access_token = creds.get("access_token")
    project_id = creds.get("project_id") or ""
    refreshed_once = False

    def _fail_payload(reason: str, plan_value: Optional[str] = None) -> dict:
        clean_reason = redact(reason)
        payload = _empty_payload(now_iso)
        payload["account"] = {"label": email or None, "plan": plan_value}
        if usage_obj is not None:
            payload["usage"] = usage_obj
            payload["warnings"] = _dedupe_redacted(
                ["实时查询 AGY 服务端失败（%s），当前仅显示本地今日 tokens" % clean_reason]
                + token_warnings
            )
            return payload
        payload["warnings"] = _dedupe_redacted(token_warnings)
        if clean_reason.startswith("查询 AGY 用量失败："):
            payload["error"] = clean_reason
        else:
            payload["error"] = redact("查询 AGY 用量失败：%s" % clean_reason)
        return payload

    if source == "local":
        expiry_epoch = creds.get("expiry_epoch")
        needs_proactive = (not access_token) or (
            expiry_epoch is not None
            and expiry_epoch <= now.timestamp() + PROACTIVE_REFRESH_SKEW_SECONDS
        )
        if needs_proactive:
            new_token, refresh_err = _refresh_access_token(creds)
            if refresh_err is not None:
                return _fail_payload(refresh_err)
            access_token = new_token
            refreshed_once = True

    assert access_token is not None

    def _post_with_retry(url: str, body_obj: dict) -> Tuple[Optional[dict], Optional[str], bool]:
        nonlocal access_token, refreshed_once
        data, err, status = _post_json_with_status(url, access_token, body_obj, source=source)
        if status == 401 and source == "local" and not refreshed_once:
            new_token, refresh_err = _refresh_access_token(creds)
            if refresh_err is not None:
                return None, refresh_err, True
            assert new_token is not None
            access_token = new_token
            refreshed_once = True
            data, err, _ = _post_json_with_status(url, access_token, body_obj, source=source)
        return data, err, False

    plan: Optional[str] = None
    if not project_id:
        load_body = {
            "metadata": {
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            }
        }
        load_data, load_err, _ = _post_with_retry(LOAD_CODE_ASSIST_URL, load_body)
        if load_err is not None:
            return _fail_payload(load_err)
        assert load_data is not None
        raw_project = load_data.get("cloudaicompanionProject")
        if isinstance(raw_project, str) and raw_project.strip():
            project_id = raw_project.strip()
        plan = _extract_plan(load_data)

    quota_req = {"project": project_id} if project_id else {}
    summary_data, summary_err, summary_refresh_failed = _post_with_retry(
        RETRIEVE_QUOTA_SUMMARY_URL,
        quota_req,
    )
    if summary_refresh_failed and summary_err is not None:
        return _fail_payload(summary_err, plan_value=plan)

    quota_data, quota_err, quota_refresh_failed = _post_with_retry(
        RETRIEVE_QUOTA_URL,
        quota_req,
    )
    if quota_refresh_failed and quota_err is not None:
        return _fail_payload(quota_err, plan_value=plan)

    if summary_data is None and quota_data is None:
        return _fail_payload(summary_err or quota_err or "未知错误", plan_value=plan)

    warnings: List[str] = []
    if summary_err is not None and quota_data is not None:
        warnings.append("AGY 配额汇总接口查询失败（%s），仅使用模型配额数据" % summary_err)
    elif quota_err is not None and summary_data is not None:
        warnings.append("AGY 模型配额接口查询失败（%s），仅使用配额汇总数据" % quota_err)

    buckets = _collect_buckets(summary_data, quota_data)
    windows = _normalize_buckets(buckets, now, warnings)

    payload = {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "account": {"label": email or None, "plan": plan},
        "generated_at": now_iso,
        "observed_at": now_iso,
        "stale": False,
        "windows": windows,
        "balance": None,
        "spend": None,
        "usage": usage_obj,
        "coverage": None,
        "warnings": _dedupe_redacted(warnings + token_warnings),
        "error": None,
    }
    _log("耗时 %.0fms（实时服务端查询成功）" % ((time.time() - started) * 1000))
    return payload


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
        payload["error"] = redact("读取 AGY 用量失败：%s" % exc)

    if not emit(payload):
        return 1
    return 0 if payload["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
