#!/usr/bin/env python3
"""AGY (Antigravity) 探针验收测试。

覆盖：零网络隔离 HOME、AGY_DISABLE_LOCAL_AUTH=1、go-keyring-base64: 解码与实时 200 保守聚合
（5h + 7d + plan + email）、本地 today_tokens 聚合与 4MB 截断警告、主动与被动 401 内存 OAuth
刷新（零写盘）、过期凭据回退（有/无本地 today_tokens）、部分端点失败与异常值、官方域名绑定、
HTTP 302 重定向防泄露（LocalPostServer）、>1MB 响应上限以及凭据脱敏。

网络一律 mock 或本地回环服务，不打真实接口；HOME 全部临时隔离，不碰真实钥匙串。
"""

from __future__ import annotations

import base64
import contextlib
import datetime
import http.server
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

FAKE_EMAIL = "agy.user@example.com"
FAKE_TOKEN = "ya29.a0AfB_bySyntheticAgyToken1234567890abcdef"
FAKE_REFRESH = "1//0eSyntheticAgyRefreshToken1234567890abcdef"
FAKE_NEW_TOKEN = "ya29.a0AfB_bySyntheticRefreshedToken9876543210"
FAKE_CLIENT_ID = "123456789-synthetic.apps.googleusercontent.com"

LOAD_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
SUMMARY_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
OAUTH_URL = "https://oauth2.googleapis.com/token"


def load_probe():
    path = support.PROBES / "agy.py"
    spec = importlib.util.spec_from_file_location("probe_agy_under_test", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def future_iso(seconds: int) -> str:
    moment = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def past_iso(seconds: int) -> str:
    moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def make_keyring_payload(
    access_token: str = FAKE_TOKEN,
    refresh_token: str = FAKE_REFRESH,
    expiry: str = None,
    email: str = FAKE_EMAIL,
    client_id: str = None,
    wrap_base64: bool = True,
) -> str:
    obj = {
        "token": {
            "access_token": access_token,
            "token_type": "Bearer",
            "refresh_token": refresh_token,
            "expiry": expiry or future_iso(3600),
            "expires_in": 3599,
        },
        "auth_method": "oauth",
        "id_token_email": email,
        "writer_id": "test-writer",
    }
    if client_id is not None:
        obj["client_id"] = client_id
    raw_json = json.dumps(obj, ensure_ascii=False)
    if wrap_base64:
        return "go-keyring-base64:" + base64.b64encode(raw_json.encode("utf-8")).decode("ascii")
    return raw_json


class FakeResponse:
    def __init__(self, body: bytes, final_url: str, headers=None):
        self._body = body
        self._final_url = final_url
        self.headers = headers or {}

    def geturl(self) -> str:
        return self._final_url

    def read(self, amount: int = -1) -> bytes:
        if amount is None or amount < 0:
            return self._body
        return self._body[:amount]

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False


class FakeOpener:
    def __init__(self, responses=None, exc=None):
        self.calls = []
        self._responses = list(responses or [])
        self._exc = exc

    def open(self, request, timeout=None):
        self.calls.append((request, timeout))
        if self._exc is not None:
            raise self._exc
        if not self._responses:
            raise AssertionError("未预期的网络请求：%s" % request.full_url)
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class LocalPostServer:
    """支持 POST 的最小本地 HTTP 服务，记录所有收到的请求头。"""

    def __init__(self, behavior):
        self.requests = []
        requests = self.requests

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0") or "0")
                _ = self.rfile.read(length) if length > 0 else b""
                requests.append((self.path, dict(self.headers.items())))
                status, headers, body = behavior(self.path)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self.do_POST()

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


def http_error(code: int, url: str = QUOTA_URL) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(url, code, "err", {}, None)


def write_transcript(base_dir: Path, conv_id: str, records: list) -> Path:
    path = base_dir / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for item in records:
            if isinstance(item, str):
                handle.write(item + "\n")
            else:
                handle.write(json.dumps(item, ensure_ascii=False) + "\n")
    return path


class AgyProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.auth_file = self.home / ".gemini" / "antigravity-cli" / "auth.json"
        self.brain_cli = self.home / ".gemini" / "antigravity-cli" / "brain"
        self.brain_ide = self.home / ".gemini" / "antigravity" / "brain"

    def tearDown(self):
        self._tmp.cleanup()

    def _run_in_process(self, probe, env=None, opener=None, argv=None):
        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()
        clean_env = {
            "HOME": str(self.home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LANG": "en_US.UTF-8",
        }
        if env:
            clean_env.update(env)
        patches = [
            mock.patch.dict(os.environ, clean_env, clear=True),
            mock.patch.object(probe, "BRAIN_DIRS", [self.brain_cli, self.brain_ide]),
            mock.patch.object(sys, "stdout", stdout_buf),
            mock.patch.object(sys, "stderr", stderr_buf),
        ]
        if opener is not None:
            patches.append(mock.patch.object(probe, "_OPENER", opener))
        with contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            code = probe.main(argv or ["agy.py"])
        stdout_text = stdout_buf.getvalue()
        stderr_text = stderr_buf.getvalue()
        lines = [line for line in stdout_text.splitlines() if line.strip()]
        self.assertEqual(len(lines), 1, "stdout 必须只有一行 JSON，实际：%r" % stdout_text)
        payload = support.strict_loads(lines[0])
        return code, payload, stdout_text, stderr_text

    def _assert_contract(self, payload: dict):
        self.assertEqual(set(payload.keys()), support.HEADER_KEYS)
        self.assertEqual(payload["schema"], "usage-lens/probe@1")
        self.assertEqual(payload["provider"], "agy")
        self.assertIsInstance(payload["warnings"], list)
        self.assertIsInstance(payload["windows"], list)
        for window in payload["windows"]:
            self.assertEqual(set(window.keys()), support.WINDOW_KEYS)

    # 1. Zero-network isolated HOME gate
    def test_isolated_home_zero_network_and_zero_writes(self):
        before = support.fingerprint(self.home)
        completed = support.run_probe("agy", self.home)
        after = support.fingerprint(self.home)

        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        self.assertEqual(before, after, "探针不得写入任何文件")
        payload = support.parse_stdout(completed)
        self._assert_contract(payload)
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["error"])
        self.assertIsNone(payload["usage"])
        self.assertIn(
            "未检测到本机 AGY 登录态，请先运行 agy 登录以查看 5 小时与 7 天用量",
            payload["warnings"],
        )

    # 2. AGY_DISABLE_LOCAL_AUTH=1 gate
    def test_disable_local_auth_skips_auth_file_and_network(self):
        probe = load_probe()
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(make_keyring_payload(), encoding="utf-8")

        opener = FakeOpener()
        code, payload, _, _ = self._run_in_process(
            probe,
            env={"AGY_DISABLE_LOCAL_AUTH": "1"},
            opener=opener,
        )
        self.assertEqual(code, 0)
        self.assertEqual(len(opener.calls), 0, "禁用本机登录态时不得发起任何网络请求")
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["error"])
        self.assertTrue(any("未检测到本机 AGY 登录态" in w for w in payload["warnings"]))

    # 3. go-keyring-base64: decoding & live 200 conservative aggregation
    def test_keyring_base64_and_live_conservative_max_aggregation(self):
        probe = load_probe()
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(make_keyring_payload(wrap_base64=True), encoding="utf-8")
        before = support.fingerprint(self.home)

        reset_5h_summary = future_iso(4 * 3600)
        reset_5h_gemini = future_iso(2 * 3600)
        reset_7d_summary = future_iso(5 * 86400)

        opener = FakeOpener(
            responses=[
                FakeResponse(
                    json.dumps(
                        {
                            "cloudaicompanionProject": "proj-agy-123",
                            "currentTier": {"id": "free-tier", "name": "Free"},
                            "paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
                        }
                    ).encode("utf-8"),
                    LOAD_URL,
                ),
                FakeResponse(
                    json.dumps(
                        {
                            "groups": [
                                {
                                    "displayName": "Claude & GPT",
                                    "buckets": [
                                        {
                                            "bucketId": "3p-5h",
                                            "window": "5h",
                                            "remainingFraction": 1.0,
                                            "resetTime": reset_5h_summary,
                                        },
                                        {
                                            "bucketId": "3p-weekly",
                                            "window": "weekly",
                                            "remainingFraction": 0.85,
                                            "resetTime": reset_7d_summary,
                                        },
                                    ],
                                }
                            ]
                        }
                    ).encode("utf-8"),
                    SUMMARY_URL,
                ),
                FakeResponse(
                    json.dumps(
                        {
                            "buckets": [
                                {
                                    "modelId": "gemini-2.5-pro",
                                    "tokenType": "WTUS",
                                    "remainingFraction": 0.41,
                                    "resetTime": reset_5h_gemini,
                                },
                                {
                                    "modelId": "gemini-2.5-flash",
                                    "tokenType": "WTUS",
                                    "remainingFraction": 0.90,
                                    "resetTime": reset_5h_summary,
                                },
                            ]
                        }
                    ).encode("utf-8"),
                    QUOTA_URL,
                ),
            ]
        )

        code, payload, stdout_text, stderr_text = self._run_in_process(probe, opener=opener)
        after = support.fingerprint(self.home)

        self.assertEqual(code, 0)
        self.assertEqual(before, after, "查询成功也不得写盘")
        self._assert_contract(payload)
        self.assertEqual(payload["account"], {"label": FAKE_EMAIL, "plan": "Google AI Pro"})
        self.assertEqual(payload["observed_at"], payload["generated_at"])
        self.assertFalse(payload["stale"])
        self.assertIsNone(payload["error"])
        self.assertEqual(len(opener.calls), 3)

        # Verify loadCodeAssist used IDE_UNSPECIFIED
        load_req, load_timeout = opener.calls[0]
        self.assertEqual(load_timeout, 3.0)
        load_body = json.loads(load_req.data.decode("utf-8"))
        self.assertEqual(load_body["metadata"]["ideType"], "IDE_UNSPECIFIED")

        by_id = {w["id"]: w for w in payload["windows"]}
        self.assertEqual(set(by_id.keys()), {"5h", "7d"})
        self.assertEqual(by_id["5h"]["label"], "5 小时")
        self.assertEqual(by_id["5h"]["used_percent"], 59.0)
        self.assertEqual(by_id["5h"]["window_seconds"], 18000)
        self.assertEqual(by_id["5h"]["resets_at"], reset_5h_gemini)
        self.assertEqual(by_id["5h"]["basis"], "server")
        self.assertFalse(by_id["5h"]["expired"])

        self.assertEqual(by_id["7d"]["label"], "7 天")
        self.assertEqual(by_id["7d"]["used_percent"], 15.0)
        self.assertEqual(by_id["7d"]["window_seconds"], 604800)
        self.assertEqual(by_id["7d"]["resets_at"], reset_7d_summary)
        self.assertEqual(by_id["7d"]["basis"], "server")

        support.assert_no_secrets(self, stdout_text)
        support.assert_no_secrets(self, stderr_text)

    # 4. Local today_tokens aggregation across both brain dirs + truncation warning
    def test_local_today_tokens_aggregation_and_truncation(self):
        probe = load_probe()
        now_local = datetime.datetime.now().astimezone()
        today_iso = now_local.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        yesterday_iso = (
            (now_local - datetime.timedelta(days=2))
            .astimezone(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        )

        write_transcript(
            self.brain_cli,
            "conv-cli-1",
            [
                "not valid json line",
                {
                    "type": "USER_INPUT",
                    "created_at": today_iso,
                    "input_tokens": 999999,
                },
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": yesterday_iso,
                    "input_tokens": 5000,
                    "output_tokens": 1000,
                    "cache_read_tokens": 2000,
                },
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": today_iso,
                    "input_tokens": 100,
                    "output_tokens": 50,
                    "cache_read_tokens": 250,
                },
            ],
        )
        write_transcript(
            self.brain_ide,
            "conv-ide-2",
            [
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": today_iso,
                    "input_tokens": 300,
                    "output_tokens": 100,
                    "cache_read_tokens": 0,
                },
            ],
        )

        # Also test isolated unauthenticated path still reports local today_tokens
        code, payload, _, _ = self._run_in_process(
            probe,
            env={"AGY_DISABLE_LOCAL_AUTH": "1"},
            opener=FakeOpener(),
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["usage"], {"today_tokens": 800, "source": "local"})
        self.assertFalse(any("末尾 4MB" in w for w in payload["warnings"]))

        # Test truncation warning when MAX_SCAN_BYTES is exceeded
        with mock.patch.object(probe, "MAX_SCAN_BYTES", 64):
            tokens, warnings = probe.find_today_tokens(
                now_local.date(), [self.brain_cli, self.brain_ide]
            )
        self.assertTrue(any("末尾 4MB" in w for w in warnings))
        self.assertIsNotNone(tokens)

    # 4b. UTC vs local date boundary aggregates today's local tokens accurately
    def test_utc_local_date_boundary_aggregates_local_today_tokens(self):
        probe = load_probe()
        # 2026-11-21T18:30:00Z is 2026-11-22 02:30:00+08:00 (UTC date != local date)
        boundary_now = datetime.datetime(2026, 11, 21, 18, 30, 0, tzinfo=datetime.timezone.utc)
        today_local_iso = "2026-11-21T18:20:00Z"  # 2026-11-22 02:20+08:00 (local today)
        yesterday_local_iso = "2026-11-21T15:00:00Z"  # 2026-11-21 23:00+08:00 (local yesterday, same UTC date)

        transcript_path = write_transcript(
            self.brain_cli,
            "conv-tz-boundary",
            [
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": yesterday_local_iso,
                    "input_tokens": 9000,
                    "output_tokens": 1000,
                    "cache_read_tokens": 0,
                },
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": today_local_iso,
                    "input_tokens": 400,
                    "output_tokens": 150,
                    "cache_read_tokens": 50,
                },
            ],
        )
        boundary_epoch = boundary_now.timestamp()
        os.utime(transcript_path, (boundary_epoch, boundary_epoch))

        prev_tz = os.environ.get("TZ")
        try:
            with mock.patch.object(probe, "utc_now", return_value=boundary_now):
                os.environ["TZ"] = "Asia/Shanghai"
                if hasattr(time, "tzset"):
                    time.tzset()
                code, payload, _, _ = self._run_in_process(
                    probe,
                    env={"AGY_DISABLE_LOCAL_AUTH": "1", "TZ": "Asia/Shanghai"},
                    opener=FakeOpener(),
                )
        finally:
            if prev_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = prev_tz
            if hasattr(time, "tzset"):
                time.tzset()

        self.assertEqual(code, 0)
        self.assertEqual(payload["usage"], {"today_tokens": 600, "source": "local"})

    # 5a. Proactive in-memory OAuth refresh (zero writes)
    def test_proactive_in_memory_oauth_refresh_zero_writes(self):
        probe = load_probe()
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(
            make_keyring_payload(
                access_token=FAKE_TOKEN,
                refresh_token=FAKE_REFRESH,
                expiry=past_iso(120),
                client_id=FAKE_CLIENT_ID,
            ),
            encoding="utf-8",
        )
        before_bytes = self.auth_file.read_bytes()

        opener = FakeOpener(
            responses=[
                FakeResponse(
                    json.dumps({"access_token": FAKE_NEW_TOKEN, "expires_in": 3600}).encode("utf-8"),
                    OAUTH_URL,
                ),
                FakeResponse(
                    json.dumps({"cloudaicompanionProject": "proj-1", "paidTier": {"name": "Pro"}}).encode("utf-8"),
                    LOAD_URL,
                ),
                FakeResponse(
                    json.dumps(
                        {
                            "groups": [
                                {
                                    "buckets": [
                                        {"window": "5h", "remainingFraction": 0.8, "resetTime": future_iso(3600)},
                                        {"window": "weekly", "remainingFraction": 0.9, "resetTime": future_iso(5 * 86400)},
                                    ]
                                }
                            ]
                        }
                    ).encode("utf-8"),
                    SUMMARY_URL,
                ),
                FakeResponse(json.dumps({"buckets": []}).encode("utf-8"), QUOTA_URL),
            ]
        )

        code, payload, stdout_text, stderr_text = self._run_in_process(probe, opener=opener)
        self.assertEqual(code, 0)
        self.assertEqual(self.auth_file.read_bytes(), before_bytes, "刷新绝不可写盘")
        self.assertEqual(opener.calls[0][0].full_url, OAUTH_URL)
        self.assertEqual(
            opener.calls[1][0].get_header("Authorization"),
            "Bearer " + FAKE_NEW_TOKEN,
        )
        self.assertEqual(len(payload["windows"]), 2)
        support.assert_no_secrets(self, stdout_text)
        support.assert_no_secrets(self, stderr_text)

    # 5b. Reactive 401 in-memory OAuth refresh (single retry guard)
    def test_reactive_401_refresh_retries_at_most_once(self):
        probe = load_probe()
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(
            make_keyring_payload(
                access_token=FAKE_TOKEN,
                refresh_token=FAKE_REFRESH,
                expiry=future_iso(3600),
                client_id=FAKE_CLIENT_ID,
            ),
            encoding="utf-8",
        )

        opener = FakeOpener(
            responses=[
                http_error(401, LOAD_URL),
                FakeResponse(
                    json.dumps({"access_token": FAKE_NEW_TOKEN}).encode("utf-8"),
                    OAUTH_URL,
                ),
                FakeResponse(
                    json.dumps({"cloudaicompanionProject": "proj-1"}).encode("utf-8"),
                    LOAD_URL,
                ),
                # Second 401 on summary must NOT trigger a second refresh
                http_error(401, SUMMARY_URL),
                http_error(401, QUOTA_URL),
            ]
        )

        code, payload, stdout_text, stderr_text = self._run_in_process(probe, opener=opener)
        self.assertEqual(code, 1)
        oauth_calls = [req for req, _ in opener.calls if req.full_url == OAUTH_URL]
        self.assertEqual(len(oauth_calls), 1, "单次探针运行最多刷新一次")
        self.assertIsNotNone(payload["error"])
        support.assert_no_secrets(self, stdout_text)
        support.assert_no_secrets(self, stderr_text)

    # 6. Expired auth without client_id: with and without local today_tokens
    def test_expired_auth_without_client_id_fallback(self):
        probe = load_probe()
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(
            make_keyring_payload(expiry=past_iso(300), client_id=None),
            encoding="utf-8",
        )

        # Without local today_tokens -> exit 1 + error
        code, payload, _, _ = self._run_in_process(probe, opener=FakeOpener())
        self.assertEqual(code, 1)
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["usage"])
        self.assertIsNotNone(payload["error"])
        self.assertIn("agy", payload["error"])

        # With local today_tokens -> exit 0 + preserve usage + warning
        now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        write_transcript(
            self.brain_cli,
            "conv-fallback",
            [
                {
                    "type": "PLANNER_RESPONSE",
                    "created_at": now_iso,
                    "input_tokens": 1200,
                    "output_tokens": 300,
                    "cache_read_tokens": 500,
                }
            ],
        )
        code2, payload2, _, _ = self._run_in_process(probe, opener=FakeOpener())
        self.assertEqual(code2, 0)
        self.assertEqual(payload2["windows"], [])
        self.assertIsNone(payload2["error"])
        self.assertEqual(payload2["usage"], {"today_tokens": 2000, "source": "local"})
        self.assertTrue(any("当前仅显示本地今日 tokens" in w for w in payload2["warnings"]))

    # 7. Partial endpoint failure & malformed/out-of-range values
    def test_partial_endpoint_failure_and_malformed_values(self):
        probe = load_probe()
        opener = FakeOpener(
            responses=[
                FakeResponse(
                    json.dumps({"cloudaicompanionProject": "proj-1"}).encode("utf-8"),
                    LOAD_URL,
                ),
                http_error(500, SUMMARY_URL),
                FakeResponse(
                    json.dumps(
                        {
                            "buckets": [
                                {
                                    "modelId": "gemini-bad",
                                    "remainingFraction": 1.5,
                                    "resetTime": future_iso(3600),
                                },
                                {
                                    "modelId": "gemini-nan",
                                    "remainingFraction": "NaN",
                                    "resetTime": future_iso(4 * 86400),
                                },
                            ]
                        }
                    ).encode("utf-8"),
                    QUOTA_URL,
                ),
            ]
        )

        code, payload, stdout_text, _ = self._run_in_process(
            probe,
            env={"AGY_ACCESS_TOKEN": FAKE_TOKEN, "AGY_ACCOUNT_EMAIL": FAKE_EMAIL},
            opener=opener,
        )
        self.assertEqual(code, 0)
        self.assertNotIn("NaN", stdout_text)
        self.assertNotIn("Infinity", stdout_text)
        by_id = {w["id"]: w for w in payload["windows"]}
        self.assertIsNone(by_id["5h"]["used_percent"])
        self.assertIsNone(by_id["7d"]["used_percent"])
        self.assertTrue(any("配额汇总接口查询失败" in w for w in payload["warnings"]))
        self.assertTrue(any("remainingFraction 数值异常" in w for w in payload["warnings"]))

    # 8a. Host pinning
    def test_host_pinning(self):
        probe = load_probe()
        self.assertTrue(probe.is_official_url("https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"))
        self.assertTrue(probe.is_official_url("https://daily-cloudcode-pa.googleapis.com:443/v1internal:loadCodeAssist"))
        self.assertFalse(probe.is_official_url("http://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"))
        self.assertFalse(probe.is_official_url("https://daily-cloudcode-pa.googleapis.com:8443/v1internal:loadCodeAssist"))
        self.assertFalse(probe.is_official_url("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"))
        self.assertFalse(probe.is_official_url("https://evil@daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"))
        self.assertFalse(probe.is_official_url("https://daily-cloudcode-pa.googleapis.com.evil.com/x"))

        self.assertTrue(probe.is_official_oauth_url("https://oauth2.googleapis.com/token"))
        self.assertTrue(probe.is_official_oauth_url("https://oauth2.googleapis.com:443/token"))
        self.assertFalse(probe.is_official_oauth_url("http://oauth2.googleapis.com/token"))
        self.assertFalse(probe.is_official_oauth_url("https://user@oauth2.googleapis.com/token"))
        self.assertFalse(probe.is_official_oauth_url("https://oauth2.googleapis.com.evil.com/token"))

    # 8b. HTTP 302 redirect rejection via LocalPostServer
    def test_redirect_302_blocked_without_leaking_auth_header(self):
        probe = load_probe()
        target = LocalPostServer(lambda path: (200, {"Content-Type": "application/json"}, b'{"ok":true}'))
        redirector = LocalPostServer(
            lambda path: (302, {"Location": target.url + "/steal"}, b"")
        )
        try:
            data, err, status = probe._post_json_with_status(
                redirector.url + "/v1internal:loadCodeAssist",
                FAKE_TOKEN,
                {"metadata": {}},
                source="local",
            )
            self.assertIsNone(data)
            self.assertEqual(status, 302)
            self.assertIn("重定向", err)
            self.assertEqual(len(target.requests), 0, "重定向目标绝不能收到任何请求或 Authorization 头")
        finally:
            redirector.close()
            target.close()

    # 8c. Oversized >1 MB response cap
    def test_oversized_response_rejected(self):
        probe = load_probe()
        oversized = b"x" * (probe.HTTP_MAX_BYTES + 10)
        opener = FakeOpener(
            responses=[
                FakeResponse(oversized, LOAD_URL),
            ]
        )
        code, payload, _, _ = self._run_in_process(
            probe,
            env={"AGY_ACCESS_TOKEN": FAKE_TOKEN},
            opener=opener,
        )
        self.assertEqual(code, 1)
        self.assertIn("1MB", payload["error"])

    # 8d. Secret redaction across stdout and stderr
    def test_secret_redaction(self):
        probe = load_probe()
        jwt = "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.syntheticSig123456"
        sample = (
            "Authorization: Bearer %s token=%s refresh=%s jwt=%s sk-testSecretKey123456"
            % (FAKE_TOKEN, FAKE_TOKEN, FAKE_REFRESH, jwt)
        )
        redacted = probe.redact(sample)
        self.assertNotIn("ya29.", redacted)
        self.assertNotIn("1//", redacted)
        self.assertNotIn("eyJ", redacted)
        self.assertNotIn("sk-testSecretKey", redacted)
        support.assert_no_secrets(self, redacted)

        # Also check error path containing secret never leaks to stdout or stderr
        opener = FakeOpener(exc=RuntimeError("boom " + sample))
        code, payload, stdout_text, stderr_text = self._run_in_process(
            probe,
            env={"AGY_ACCESS_TOKEN": FAKE_TOKEN},
            opener=opener,
        )
        self.assertEqual(code, 1)
        self.assertNotIn("ya29.", stdout_text)
        self.assertNotIn("1//", stdout_text)
        self.assertNotIn("eyJ", stdout_text)
        self.assertNotIn("ya29.", stderr_text)
        support.assert_no_secrets(self, stdout_text)
        support.assert_no_secrets(self, stderr_text)


if __name__ == "__main__":
    unittest.main()
