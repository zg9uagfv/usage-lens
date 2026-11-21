#!/usr/bin/env python3
"""Gemini 探针验收：账号门控、5h/7d 窗口映射、多模型聚合、异常值、HTTP 错误、302 防泄露与凭据脱敏。

网络一律 mock 或本地回环服务，不打真实接口；HOME 全部临时隔离。
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

FAKE_EMAIL = "user@gmail.com"
FAKE_TOKEN = "ya29.a0AfB_byTestSecretToken1234567890abcdef"
FAKE_REFRESH = "1//0eTestRefreshToken1234567890abcdef"
LOAD_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
OAUTH_URL = "https://oauth2.googleapis.com/token"


def make_fake_jwt(claims: dict) -> str:
    header = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').decode("ascii").rstrip("=")
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode("utf-8")).decode("ascii").rstrip("=")
    return "%s.%s.fakesig_test_only_12345" % (header, payload)


def load_probe():
    path = support.PROBES / "gemini.py"
    spec = importlib.util.spec_from_file_location("probe_gemini_under_test", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def future_iso(seconds: int) -> str:
    moment = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def past_iso(seconds: int) -> str:
    moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


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


class GeminiProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.module = load_probe()

    def tearDown(self):
        self._tmp.cleanup()

    def _build(self, email=None, token=None, project_id=None, extra_env=None):
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in (
                "GEMINI_ACCOUNT_EMAIL",
                "GEMINI_ACCESS_TOKEN",
                "GEMINI_PROJECT_ID",
                "GEMINI_DISABLE_LOCAL_AUTH",
                "GEMINI_OAUTH_CLIENT_ID",
                "GEMINI_OAUTH_CLIENT_SECRET",
            )
        }
        env["HOME"] = str(self.home)
        if email is not None:
            env["GEMINI_ACCOUNT_EMAIL"] = email
        if token is not None:
            env["GEMINI_ACCESS_TOKEN"] = token
        if project_id is not None:
            env["GEMINI_PROJECT_ID"] = project_id
        if extra_env:
            env.update(extra_env)
        with mock.patch.dict(os.environ, env, clear=True):
            return self.module.build_payload()

    def _write_local_oauth_creds(self, payload: dict, active_email: str | None = None):
        gemini_dir = self.home / ".gemini"
        gemini_dir.mkdir(parents=True, exist_ok=True)
        (gemini_dir / "oauth_creds.json").write_text(json.dumps(payload), encoding="utf-8")
        if active_email is not None:
            (gemini_dir / "google_accounts.json").write_text(
                json.dumps({"active": active_email, "old": []}),
                encoding="utf-8",
            )

    # ---------- 账号门控（零网络、零写盘） ----------

    def test_no_account_exits_zero_with_guidance_and_zero_files(self):
        before = support.fingerprint(self.home)
        completed = support.run_probe("gemini", self.home)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        payload = support.parse_stdout(completed)

        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertEqual(payload["schema"], "usage-lens/probe@1")
        self.assertEqual(payload["provider"], "gemini")
        self.assertEqual(payload["windows"], [])
        self.assertEqual(payload["account"], {"label": None, "plan": None})
        self.assertIsNone(payload["balance"])
        self.assertIsNone(payload["spend"])
        self.assertIsNone(payload["usage"])
        self.assertIsNone(payload["error"])
        self.assertFalse(payload["stale"])
        self.assertTrue(
            any("提供 Gemini 账号" in item for item in payload["warnings"]),
            payload["warnings"],
        )
        self.assertEqual(support.fingerprint(self.home), before)
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))
        support.assert_no_secrets(self, completed.stderr.decode("utf-8"))

    def test_no_account_or_blank_token_makes_zero_network_calls(self):
        for email, token in [(None, None), (FAKE_EMAIL, ""), (FAKE_EMAIL, "   ")]:
            with self.subTest(email=email, token=token):
                opener = FakeOpener(exc=AssertionError("未配置账号不该发起任何网络请求"))
                with mock.patch.object(self.module, "_OPENER", opener):
                    payload = self._build(email=email, token=token)
                self.assertEqual(opener.calls, [])
                self.assertEqual(payload["windows"], [])
                self.assertIsNone(payload["error"])
                self.assertTrue(any("提供 Gemini 账号" in w for w in payload["warnings"]))

    def test_unknown_argument_exits_2_with_single_json_line(self):
        completed = support.run_probe("gemini", self.home, args=["--debug"])
        self.assertEqual(completed.returncode, 2)
        payload = support.parse_stdout(completed)
        self.assertIn("不支持的参数", payload["error"])

    # ---------- 5h + 7d 窗口映射与多模型聚合 ----------

    def test_valid_account_returns_5h_and_7d_windows(self):
        reset_5h = future_iso(3 * 3600)
        reset_7d = future_iso(4 * 86400)
        load_resp = FakeResponse(
            json.dumps({
                "cloudaicompanionProject": "projects/demo-123",
                "currentTier": {"id": "pro", "name": "Gemini Pro"},
            }).encode("utf-8"),
            LOAD_URL,
        )
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.65, "resetTime": reset_5h, "windowDuration": "PT5H"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.40, "resetTime": reset_7d, "windowDuration": "P7D"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[load_resp, quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN)

        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertIsNone(payload["error"])
        self.assertEqual(payload["account"], {"label": FAKE_EMAIL, "plan": "pro"})
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(len(payload["windows"]), 2)

        w5h, w7d = payload["windows"]
        self.assertEqual(set(w5h), support.WINDOW_KEYS)
        self.assertEqual(w5h["id"], "5h")
        self.assertEqual(w5h["label"], "5 小时")
        self.assertEqual(w5h["window_seconds"], 18000)
        self.assertAlmostEqual(w5h["used_percent"], 35.0, places=2)
        self.assertEqual(w5h["resets_at"], reset_5h)
        self.assertFalse(w5h["expired"])
        self.assertEqual(w5h["basis"], "server")

        self.assertEqual(w7d["id"], "7d")
        self.assertEqual(w7d["label"], "7 天")
        self.assertEqual(w7d["window_seconds"], 604800)
        self.assertAlmostEqual(w7d["used_percent"], 60.0, places=2)
        self.assertEqual(w7d["resets_at"], reset_7d)
        self.assertFalse(w7d["expired"])
        self.assertEqual(w7d["basis"], "server")

        self.assertEqual(len(opener.calls), 2)
        req1, t1 = opener.calls[0]
        req2, t2 = opener.calls[1]
        self.assertEqual(req1.full_url, LOAD_URL)
        self.assertEqual(req2.full_url, QUOTA_URL)
        self.assertEqual(req1.get_header("Authorization"), "Bearer " + FAKE_TOKEN)
        self.assertEqual(req2.get_header("Authorization"), "Bearer " + FAKE_TOKEN)
        self.assertLessEqual(t1, 3.0)
        self.assertLessEqual(t2, 3.0)
        self.assertEqual(json.loads(req2.data.decode("utf-8")), {"project": "projects/demo-123"})

        rendered = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn(FAKE_TOKEN, rendered)
        support.assert_no_secrets(self, rendered)

    def test_explicit_project_id_skips_load_code_assist(self):
        reset_5h = future_iso(2 * 3600)
        reset_7d = future_iso(5 * 86400)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": reset_5h},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.50, "resetTime": reset_7d},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="projects/explicit-1")

        self.assertEqual(len(opener.calls), 1)
        self.assertEqual(opener.calls[0][0].full_url, QUOTA_URL)
        self.assertEqual(json.loads(opener.calls[0][0].data.decode("utf-8")), {"project": "projects/explicit-1"})
        self.assertEqual([w["id"] for w in payload["windows"]], ["5h", "7d"])

    def test_multi_bucket_aggregation_picks_highest_usage(self):
        reset_pro = future_iso(3600)
        reset_flash = future_iso(7200)
        reset_7d_pro = future_iso(3 * 86400)
        reset_7d_flash = future_iso(6 * 86400)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-flash", "remainingFraction": 0.80, "resetTime": reset_flash},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.35, "resetTime": reset_pro},
                    {"modelId": "gemini-2.5-flash", "remainingFraction": 0.90, "resetTime": reset_7d_flash},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.15, "resetTime": reset_7d_pro},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")

        w5h, w7d = payload["windows"]
        self.assertAlmostEqual(w5h["used_percent"], 65.0, places=2)
        self.assertEqual(w5h["resets_at"], reset_pro)
        self.assertAlmostEqual(w7d["used_percent"], 85.0, places=2)
        self.assertEqual(w7d["resets_at"], reset_7d_pro)

    def test_partial_window_warns_without_fabricating_zero(self):
        reset_5h = future_iso(3600)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.50, "resetTime": reset_5h, "windowDuration": "5h"}
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")

        self.assertEqual(len(payload["windows"]), 1)
        self.assertEqual(payload["windows"][0]["id"], "5h")
        self.assertTrue(any("7 天" in w for w in payload["warnings"]), payload["warnings"])

    def test_expired_and_invalid_values_stay_strict_json(self):
        expired_reset = past_iso(1800)
        future_7d = future_iso(3 * 86400)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 1.5, "resetTime": expired_reset, "windowDuration": "5h"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": "NaN", "resetTime": future_7d, "windowDuration": "7d"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")

        text = json.dumps(payload, ensure_ascii=False, allow_nan=False)
        parsed = support.strict_loads(text)
        w5h, w7d = parsed["windows"]
        self.assertIsNone(w5h["used_percent"])
        self.assertTrue(w5h["expired"])
        self.assertIsNone(w7d["used_percent"])
        self.assertFalse(w7d["expired"])
        self.assertTrue(any("remainingFraction" in w for w in parsed["warnings"]))
        self.assertTrue(any("重置" in w for w in parsed["warnings"]))

    # ---------- HTTP 错误、超时、格式异常 ----------

    def test_http_errors_produce_chinese_error_and_nonzero_exit(self):
        cases = [
            (401, "凭据无效或已过期"),
            (403, "凭据无效或已过期"),
            (429, "限流"),
            (500, "暂时不可用"),
            (302, "拒绝跟随"),
        ]
        for code, expected in cases:
            with self.subTest(code=code):
                opener = FakeOpener(exc=http_error(code, LOAD_URL))
                with mock.patch.object(self.module, "_OPENER", opener):
                    stdout_buf = io.StringIO()
                    stderr_buf = io.StringIO()
                    env = {
                        "GEMINI_ACCOUNT_EMAIL": FAKE_EMAIL,
                        "GEMINI_ACCESS_TOKEN": FAKE_TOKEN,
                    }
                    with mock.patch.dict(os.environ, env, clear=True), \
                         mock.patch.object(sys, "stdout", stdout_buf), \
                         mock.patch.object(sys, "stderr", stderr_buf):
                        rc = self.module.main(["gemini.py"])
                self.assertEqual(rc, 1)
                payload = support.strict_loads(stdout_buf.getvalue().strip())
                self.assertEqual(payload["windows"], [])
                self.assertIn(expected, payload["error"] or "")
                self.assertNotIn(FAKE_TOKEN, stdout_buf.getvalue())
                self.assertNotIn(FAKE_TOKEN, stderr_buf.getvalue())

    def test_timeout_malformed_json_and_oversized_response(self):
        cases = [
            (FakeOpener(exc=TimeoutError("timed out")), "超时"),
            (FakeOpener(responses=[FakeResponse(b"<html>bad</html>", QUOTA_URL)]), "合法 JSON"),
            (
                FakeOpener(responses=[FakeResponse(b"{}", QUOTA_URL, headers={"Content-Length": str(2 * 1024 * 1024)})]),
                "过大",
            ),
            (
                FakeOpener(responses=[FakeResponse(b"{}", "https://evil.example/steal")]),
                "官方域名",
            ),
        ]
        for opener, expected in cases:
            with self.subTest(expected=expected):
                with mock.patch.object(self.module, "_OPENER", opener):
                    payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")
                self.assertEqual(payload["windows"], [])
                self.assertIn(expected, payload["error"] or "")

    # ---------- 官方域名校验与 302 重定向防泄露 ----------

    def test_is_official_url_unit(self):
        cases = {
            LOAD_URL: True,
            QUOTA_URL: True,
            "https://cloudcode-pa.googleapis.com:443/v1internal:retrieveUserQuota": True,
            "http://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota": False,
            "https://cloudcode-pa.googleapis.com.evil.com/x": False,
            "https://evil.com/cloudcode-pa.googleapis.com": False,
            "https://cloudcode-pa.googleapis.com:8443/x": False,
            "https://cloudcode-pa.googleapis.com@evil.com/x": False,
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(self.module.is_official_url(url), expected)

    def test_redirect_never_leaks_authorization(self):
        target = LocalPostServer(lambda path: (200, {}, b"{}"))
        source = LocalPostServer(
            lambda path: (302, {"Location": target.url + "/steal"}, b"")
        )
        self.addCleanup(target.close)
        self.addCleanup(source.close)

        with mock.patch.object(self.module, "RETRIEVE_QUOTA_URL", source.url + "/quota"):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")

        self.assertEqual(payload["windows"], [])
        self.assertIsNotNone(payload["error"])
        self.assertTrue(
            ("拒绝跟随" in payload["error"]) or ("官方域名" in payload["error"]),
            payload["error"],
        )
        # 关键断言：重定向目标未收到任何请求，Authorization 未泄露
        self.assertEqual(target.requests, [])
        self.assertEqual(len(source.requests), 1)
        self.assertIn("Authorization", source.requests[0][1])
        self.assertNotIn(FAKE_TOKEN, json.dumps(payload, ensure_ascii=False))

    # ---------- 凭据脱敏 ----------

    def test_secret_redaction_strips_google_tokens_and_jwt(self):
        fake_jwt = make_fake_jwt({"email": "secret@example.com"})
        leaked = "err %s and %s and Bearer %s and %s" % (FAKE_TOKEN, FAKE_REFRESH, FAKE_TOKEN, fake_jwt)
        opener = FakeOpener(exc=RuntimeError(leaked))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email=FAKE_EMAIL, token=FAKE_TOKEN, project_id="p1")

        rendered = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn("ya29.", rendered)
        self.assertNotIn("1//", rendered)
        self.assertNotIn(FAKE_TOKEN, rendered)
        self.assertNotIn(FAKE_REFRESH, rendered)
        self.assertNotIn(fake_jwt, rendered)
        self.assertIn("[redacted]", rendered)
        support.assert_no_secrets(self, rendered)

    # ---------- 本机凭据自动复用与内存刷新 ----------

    def test_manual_env_overrides_local_oauth_creds(self):
        local_token = "ya29.localShouldNotBeUsed1234567890"
        self._write_local_oauth_creds(
            {
                "access_token": local_token,
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() + 3600) * 1000),
            },
            active_email="local@gmail.com",
        )
        reset_5h = future_iso(3600)
        reset_7d = future_iso(4 * 86400)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.70, "resetTime": reset_5h, "windowDuration": "5h"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.50, "resetTime": reset_7d, "windowDuration": "7d"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(email="manual@gmail.com", token=FAKE_TOKEN, project_id="p-manual")

        self.assertIsNone(payload["error"])
        self.assertEqual(payload["account"]["label"], "manual@gmail.com")
        self.assertEqual(len(opener.calls), 1)
        self.assertEqual(opener.calls[0][0].get_header("Authorization"), "Bearer " + FAKE_TOKEN)

    def test_local_fresh_oauth_creds_reused_readonly_with_google_accounts_email(self):
        local_token = "ya29.localFreshToken1234567890abcdef"
        self._write_local_oauth_creds(
            {
                "access_token": local_token,
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() + 3600) * 1000),
            },
            active_email="local.cli@gmail.com",
        )
        before = support.fingerprint(self.home)
        reset_5h = future_iso(3600)
        reset_7d = future_iso(5 * 86400)
        load_resp = FakeResponse(
            json.dumps({"cloudaicompanionProject": "projects/local-1", "currentTier": {"id": "pro"}}).encode("utf-8"),
            LOAD_URL,
        )
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.80, "resetTime": reset_5h, "windowDuration": "PT5H"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.60, "resetTime": reset_7d, "windowDuration": "P7D"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[load_resp, quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build()

        self.assertIsNone(payload["error"])
        self.assertEqual(payload["account"], {"label": "local.cli@gmail.com", "plan": "pro"})
        self.assertEqual([w["id"] for w in payload["windows"]], ["5h", "7d"])
        self.assertEqual(opener.calls[0][0].get_header("Authorization"), "Bearer " + local_token)
        self.assertEqual(support.fingerprint(self.home), before)
        self.assertNotIn(local_token, json.dumps(payload, ensure_ascii=False))

    def test_local_email_falls_back_to_id_token_jwt_claim(self):
        local_token = "ya29.localJwtEmailToken1234567890abcdef"
        self._write_local_oauth_creds(
            {
                "access_token": local_token,
                "id_token": make_fake_jwt({"email": "jwt.local@gmail.com"}),
                "expiry_date": int((time.time() + 3600) * 1000),
            }
        )
        reset_5h = future_iso(3600)
        reset_7d = future_iso(5 * 86400)
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": reset_5h, "windowDuration": "5h"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.55, "resetTime": reset_7d, "windowDuration": "7d"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(project_id="p-jwt")

        self.assertIsNone(payload["error"])
        self.assertEqual(payload["account"]["label"], "jwt.local@gmail.com")

    def test_proactive_in_memory_refresh_on_expired_local_token_writes_zero_files(self):
        old_token = "ya29.expiredLocalToken1234567890abcdef"
        refreshed_token = "ya29.refreshedMemoryToken1234567890abcdef"
        self._write_local_oauth_creds(
            {
                "access_token": old_token,
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() - 120) * 1000),
                "client_id": "test-client-id.apps.googleusercontent.com",
                "client_secret": "test-client-secret-value",
            },
            active_email="refresh.proactive@gmail.com",
        )
        before = support.fingerprint(self.home)
        before_content = (self.home / ".gemini" / "oauth_creds.json").read_text(encoding="utf-8")

        refresh_resp = FakeResponse(
            json.dumps({"access_token": refreshed_token, "expires_in": 3600}).encode("utf-8"),
            OAUTH_URL,
        )
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.50, "resetTime": future_iso(3600), "windowDuration": "5h"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.30, "resetTime": future_iso(4 * 86400), "windowDuration": "7d"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[refresh_resp, quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(project_id="p-refresh")

        self.assertIsNone(payload["error"])
        self.assertEqual(len(opener.calls), 2)
        self.assertEqual(opener.calls[0][0].full_url, OAUTH_URL)
        self.assertEqual(opener.calls[1][0].full_url, QUOTA_URL)
        self.assertEqual(opener.calls[1][0].get_header("Authorization"), "Bearer " + refreshed_token)
        self.assertEqual([w["id"] for w in payload["windows"]], ["5h", "7d"])
        self.assertEqual(support.fingerprint(self.home), before)
        self.assertEqual((self.home / ".gemini" / "oauth_creds.json").read_text(encoding="utf-8"), before_content)

    def test_reactive_in_memory_refresh_on_http_401_writes_zero_files(self):
        stale_token = "ya29.staleLocalToken1234567890abcdef"
        refreshed_token = "ya29.reactiveRefreshedToken1234567890abcdef"
        self._write_local_oauth_creds(
            {
                "access_token": stale_token,
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() + 3600) * 1000),
                "client_id": "test-client-id.apps.googleusercontent.com",
            },
            active_email="refresh.reactive@gmail.com",
        )
        before = support.fingerprint(self.home)

        refresh_resp = FakeResponse(
            json.dumps({"access_token": refreshed_token, "expires_in": 3600}).encode("utf-8"),
            OAUTH_URL,
        )
        quota_resp = FakeResponse(
            json.dumps({
                "buckets": [
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.60, "resetTime": future_iso(3600), "windowDuration": "5h"},
                    {"modelId": "gemini-2.5-pro", "remainingFraction": 0.40, "resetTime": future_iso(4 * 86400), "windowDuration": "7d"},
                ]
            }).encode("utf-8"),
            QUOTA_URL,
        )
        opener = FakeOpener(responses=[http_error(401, QUOTA_URL), refresh_resp, quota_resp])
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(project_id="p-reactive")

        self.assertIsNone(payload["error"])
        self.assertEqual(len(opener.calls), 3)
        self.assertEqual(opener.calls[0][0].get_header("Authorization"), "Bearer " + stale_token)
        self.assertEqual(opener.calls[1][0].full_url, OAUTH_URL)
        self.assertEqual(opener.calls[2][0].get_header("Authorization"), "Bearer " + refreshed_token)
        self.assertEqual(support.fingerprint(self.home), before)

    def test_refresh_redirect_rejected_without_leaking_refresh_token(self):
        self._write_local_oauth_creds(
            {
                "access_token": "ya29.expiredToken1234567890abcdef",
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() - 60) * 1000),
                "client_id": "test-client-id.apps.googleusercontent.com",
            },
            active_email="redirect.refresh@gmail.com",
        )
        target = LocalPostServer(lambda path: (200, {}, b"{}"))
        source = LocalPostServer(lambda path: (302, {"Location": target.url + "/steal"}, b""))
        self.addCleanup(target.close)
        self.addCleanup(source.close)

        with mock.patch.object(self.module, "OAUTH_TOKEN_URL", source.url + "/token"):
            payload = self._build(project_id="p-redirect")

        self.assertEqual(target.requests, [])
        self.assertEqual(len(source.requests), 1)
        self.assertIsNotNone(payload["error"])
        self.assertTrue(
            ("拒绝跟随" in payload["error"]) or ("官方域名" in payload["error"]),
            payload["error"],
        )
        rendered = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn(FAKE_REFRESH, rendered)
        support.assert_no_secrets(self, rendered)

    def test_expired_local_token_without_refresh_or_failed_refresh_exits_nonzero(self):
        self._write_local_oauth_creds(
            {
                "access_token": "ya29.expiredNoRefresh1234567890abcdef",
                "expiry_date": int((time.time() - 120) * 1000),
            },
            active_email="expired@gmail.com",
        )
        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()
        env = {"HOME": str(self.home)}
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(sys, "stdout", stdout_buf), \
             mock.patch.object(sys, "stderr", stderr_buf):
            rc = self.module.main(["gemini.py"])

        self.assertEqual(rc, 1)
        payload = support.strict_loads(stdout_buf.getvalue().strip())
        self.assertEqual(payload["windows"], [])
        self.assertIn("缺少刷新凭据", payload["error"] or "")
        support.assert_no_secrets(self, stdout_buf.getvalue())

        # Refresh HTTP 400 failure
        self._write_local_oauth_creds(
            {
                "access_token": "ya29.expiredFailRefresh1234567890abcdef",
                "refresh_token": FAKE_REFRESH,
                "expiry_date": int((time.time() - 120) * 1000),
                "client_id": "test-client-id.apps.googleusercontent.com",
            },
            active_email="expired@gmail.com",
        )
        opener = FakeOpener(exc=http_error(400, OAUTH_URL))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload2 = self._build(project_id="p-fail")
        self.assertEqual(payload2["windows"], [])
        self.assertIn("刷新失败（HTTP 400）", payload2["error"] or "")

    def test_disable_local_auth_env_hits_zero_network_gate(self):
        self._write_local_oauth_creds(
            {
                "access_token": "ya29.localShouldBeIgnored1234567890",
                "expiry_date": int((time.time() + 3600) * 1000),
            },
            active_email="ignored@gmail.com",
        )
        opener = FakeOpener(exc=AssertionError("禁用本机凭据时不该发起网络请求"))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(extra_env={"GEMINI_DISABLE_LOCAL_AUTH": "1"})

        self.assertEqual(opener.calls, [])
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["error"])
        self.assertTrue(any("提供 Gemini 账号" in w for w in payload["warnings"]))

    def test_is_official_oauth_url_unit(self):
        cases = {
            OAUTH_URL: True,
            "https://oauth2.googleapis.com:443/token": True,
            "http://oauth2.googleapis.com/token": False,
            "https://oauth2.googleapis.com.evil.com/token": False,
            "https://oauth2.googleapis.com:8443/token": False,
            "https://oauth2.googleapis.com@evil.com/token": False,
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(self.module.is_official_oauth_url(url), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
