#!/usr/bin/env python3
"""DeepSeek 探针验收：无窗口、余额（无 key / 429 / 5xx / 302）、真实 projcache 与 data.usage 花费、防泄露。

网络一律 mock 或本地回环服务，不打真实接口；HOME 全部临时隔离。
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

FAKE_KEY = "sk-test-1234567890abcdefghij"
OFFICIAL_URL = "https://api.deepseek.com/user/balance"
BALANCE_BODY = {
    "is_available": True,
    "balance_infos": [
        {
            "currency": "CNY",
            "total_balance": "88.50",
            "granted_balance": "8.50",
            "topped_up_balance": "80.00",
        }
    ],
}


def load_probe():
    path = support.PROBES / "deepseek.py"
    spec = importlib.util.spec_from_file_location("probe_deepseek_under_test", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse:
    headers = {}

    def __init__(self, body: bytes, final_url: str = OFFICIAL_URL):
        self._body = body
        self._final_url = final_url

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
    def __init__(self, response=None, exc=None):
        self.calls = []
        self.response = response
        self.exc = exc

    def open(self, request, timeout=None):
        self.calls.append((request, timeout))
        if self.exc is not None:
            raise self.exc
        return self.response


def http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(OFFICIAL_URL, code, "err", {}, None)


def today_ms() -> int:
    return int(datetime.datetime.now().timestamp() * 1000)


class DeepSeekProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.sessions = self.home / ".dsh" / "sessions"
        self.projcache = self.home / ".dsh" / "storages" / "session_projcache" / "sessions"
        self.module = load_probe()
        self.module.PROJCACHE_DIR = self.projcache
        self.module.SESSIONS_DIR = self.sessions

    def tearDown(self):
        self._tmp.cleanup()

    def _build(self, key=None):
        env = {k: v for k, v in os.environ.items() if k != "DEEPSEEK_API_KEY"}
        if key is not None:
            env["DEEPSEEK_API_KEY"] = key
        with mock.patch.dict(os.environ, env, clear=True):
            return self.module.build_payload()

    def _build_offline(self):
        """确保不发网络请求：任何 open 调用都会炸。"""
        opener = FakeOpener(exc=AssertionError("不该发网络请求"))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build()
        return payload, opener

    # ---------- 端到端 ----------

    def test_no_key_exits_zero_balance_null_with_warning(self):
        completed = support.run_probe("deepseek", self.home)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        payload = support.parse_stdout(completed)
        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertEqual(payload["schema"], "usage-lens/probe@1")
        self.assertEqual(payload["provider"], "deepseek")
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["balance"])
        self.assertTrue(any("API key" in item for item in payload["warnings"]))
        self.assertIsNone(payload["error"])
        self.assertFalse(payload["stale"])
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))
        support.assert_no_secrets(self, completed.stderr.decode("utf-8"))

    def test_no_key_makes_no_network_call(self):
        payload, opener = self._build_offline()
        self.assertEqual(opener.calls, [])
        self.assertIsNone(payload["balance"])

    def test_windows_always_empty_and_error_clear(self):
        completed = support.run_probe("deepseek", self.home, env_extra={"DEEPSEEK_API_KEY": ""})
        payload = support.parse_stdout(completed)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["windows"], [])
        self.assertIsNone(payload["error"])
        self.assertIsNone(payload["balance"])

    def test_unknown_argument_returns_exit_2_and_single_json_line(self):
        completed = support.run_probe("deepseek", self.home, args=["--debug"])
        self.assertEqual(completed.returncode, 2)
        payload = support.parse_stdout(completed)
        self.assertIn("不支持的参数", payload["error"])

    def test_missing_dsh_dirs_give_warnings(self):
        shutil.rmtree(self.home / ".dsh")
        payload, _ = self._build_offline()
        self.assertIsNone(payload["spend"])
        self.assertIsNone(payload["coverage"])
        self.assertTrue(any("无法估算" in item for item in payload["warnings"]))

    def test_probe_writes_no_files(self):
        before = support.fingerprint(self.home)
        support.run_probe("deepseek", self.home)
        support.run_probe("codex", self.home)
        self.assertEqual(support.fingerprint(self.home), before)

    # ---------- 花费：projcache 主源 ----------

    def test_projcache_real_shape_drives_spend(self):
        support.write_projcache(
            self.home,
            "session-aaaa",
            {
                "uncachedInputTokens": 1_000_000,
                "outputTokens": 100_000,
                "cacheReadTokens": 500_000,
                "cacheWriteTokens": 0,
            },
            created_at_ms=today_ms(),
        )
        payload, _ = self._build_offline()
        spend = payload["spend"]
        self.assertIsNotNone(spend)
        # 1M 未命中 *2 + 0.5M 命中 *0.2 + 0.1M 输出 *3 = 2.4
        self.assertAlmostEqual(spend["today"], 2.4, places=4)
        self.assertAlmostEqual(spend["window"], 2.4, places=4)
        self.assertAlmostEqual(spend["total"], 2.4, places=4)
        self.assertEqual(spend["currency"], "CNY")
        self.assertEqual(spend["source"], "estimate")
        self.assertIn("按会话聚合", payload["coverage"]["note"])
        today = datetime.date.today().isoformat()
        self.assertEqual(payload["coverage"]["from"], today)
        self.assertEqual(payload["coverage"]["to"], today)
        self.assertTrue(any("牌价" in item for item in payload["warnings"]))
        self.assertEqual(payload["windows"], [])

    def test_projcache_zero_totals_falls_back_to_events(self):
        support.write_projcache(
            self.home,
            "session-zero",
            {"uncachedInputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0},
            created_at_ms=today_ms(),
        )
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        support.write_usage_archive(
            self.home,
            "session-zero",
            [support.usage_event(today_ms(),
                                 {"inputTokens": 1_000_000, "outputTokens": 100_000,
                                  "cacheReadTokens": 500_000})],
        )
        payload, _ = self._build_offline()
        self.assertAlmostEqual(payload["spend"]["today"], 2.4, places=4)
        self.assertAlmostEqual(payload["spend"]["total"], 2.4, places=4)
        self.assertIn("按事件时间", payload["coverage"]["note"])
        self.assertTrue(any("projcache 里的 token 用量为 0" in item for item in payload["warnings"]))

    def test_both_sources_prefers_projcache(self):
        support.write_projcache(
            self.home,
            "session-both",
            {"uncachedInputTokens": 1_000_000, "outputTokens": 100_000,
             "cacheReadTokens": 500_000, "cacheWriteTokens": 0},
            created_at_ms=today_ms(),
        )
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        support.write_usage_archive(
            self.home,
            "session-both",
            [support.usage_event(today_ms(), {"inputTokens": 0, "outputTokens": 1_000_000})],
        )
        payload, _ = self._build_offline()
        # 事件侧会是 3.0；主源 projcache 的 2.4 必须胜出，且不许相加
        self.assertAlmostEqual(payload["spend"]["today"], 2.4, places=4)
        self.assertAlmostEqual(payload["spend"]["total"], 2.4, places=4)
        self.assertIn("按会话聚合", payload["coverage"]["note"])

    # ---------- 花费：事件次源 ----------

    def test_events_only_usage_shape(self):
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        support.write_usage_archive(
            self.home,
            "session-events",
            [support.usage_event(today_ms(),
                                 {"inputTokens": 1_000_000, "outputTokens": 100_000,
                                  "cacheReadTokens": 500_000, "cacheWriteTokens": 0})],
        )
        payload, _ = self._build_offline()
        # inputTokens 不含 cache（DSH 源码口径），所以是 2.4 而不是 1.4
        self.assertAlmostEqual(payload["spend"]["today"], 2.4, places=4)
        self.assertAlmostEqual(payload["spend"]["total"], 2.4, places=4)
        self.assertIn("按事件时间", payload["coverage"]["note"])

    def test_events_aggregate_multiple_days(self):
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        now = datetime.datetime.now()
        yesterday = now - datetime.timedelta(days=1)
        support.write_usage_archive(
            self.home,
            "session-days",
            [
                support.usage_event(int(yesterday.timestamp() * 1000), {"outputTokens": 1_000_000}),
                support.usage_event(int(now.timestamp() * 1000), {"inputTokens": 1_000_000}),
            ],
        )
        payload, _ = self._build_offline()
        self.assertAlmostEqual(payload["spend"]["today"], 2.0, places=4)
        self.assertAlmostEqual(payload["spend"]["window"], 5.0, places=4)
        self.assertAlmostEqual(payload["spend"]["total"], 5.0, places=4)
        self.assertEqual(payload["coverage"]["from"], yesterday.date().isoformat())
        self.assertEqual(payload["coverage"]["to"], datetime.date.today().isoformat())

    def test_usage_event_without_time_uses_mtime_and_warns(self):
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        support.write_usage_archive(
            self.home,
            "session-notime",
            [{"type": "step/usage", "seq": 1, "data": {"usage": {"outputTokens": 1_000_000}}}],
        )
        payload, _ = self._build_offline()
        self.assertIsNotNone(payload["spend"])
        self.assertTrue(any("文件修改时间" in item for item in payload["warnings"]))

    def test_unrecognized_usage_fields_warn(self):
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        support.write_usage_archive(
            self.home,
            "session-weird",
            [support.usage_event(today_ms(), {"someOtherField": 42})],
        )
        payload, _ = self._build_offline()
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("字段未识别" in item for item in payload["warnings"]))

    def test_corrupt_archive_is_skipped_with_warning(self):
        workspace = self.sessions / "ws"
        workspace.mkdir(parents=True)
        (workspace / "session.v4.jsonl.zstd").write_bytes(b"this is not zstd at all")
        payload, _ = self._build_offline()
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("解压" in item for item in payload["warnings"]))

    def test_missing_zstd_gives_warning(self):
        workspace = self.sessions / "ws"
        workspace.mkdir(parents=True)
        (workspace / "session.v4.jsonl.zstd").write_bytes(b"placeholder")
        with mock.patch.object(self.module, "ZSTD_BIN", "/nonexistent/zstd"), mock.patch.object(
            self.module.shutil, "which", return_value=None
        ):
            payload, _ = self._build_offline()
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("zstd" in item for item in payload["warnings"]))

    def test_spend_window_excludes_projcache_older_than_7_days(self):
        eight_days_ago = datetime.datetime.now() - datetime.timedelta(days=8)
        support.write_projcache(
            self.home,
            "session-old",
            {"uncachedInputTokens": 1_000_000, "outputTokens": 0,
             "cacheReadTokens": 0, "cacheWriteTokens": 0},
            created_at_ms=int(eight_days_ago.timestamp() * 1000),
        )
        support.write_projcache(
            self.home,
            "session-new",
            {"uncachedInputTokens": 0, "outputTokens": 1_000_000,
             "cacheReadTokens": 0, "cacheWriteTokens": 0},
            created_at_ms=today_ms(),
        )
        payload, _ = self._build_offline()
        spend = payload["spend"]
        self.assertAlmostEqual(spend["today"], 3.0, places=4)   # 今天：1M 输出 *3
        self.assertAlmostEqual(spend["window"], 3.0, places=4)  # 近 7 天：不含 8 天前
        self.assertAlmostEqual(spend["total"], 5.0, places=4)   # 全部：含 8 天前
        self.assertEqual(payload["coverage"]["from"], eight_days_ago.date().isoformat())
        self.assertIn("window=近 7 天", payload["coverage"]["note"])
        self.assertIn("total=全部可读记录", payload["coverage"]["note"])

    def test_spend_window_excludes_events_older_than_7_days(self):
        if not support.zstd_available():
            self.skipTest("需要 zstd")
        now = datetime.datetime.now()
        eight_days_ago = now - datetime.timedelta(days=8)
        support.write_usage_archive(
            self.home,
            "session-window",
            [
                support.usage_event(int(eight_days_ago.timestamp() * 1000),
                                    {"inputTokens": 1_000_000}),
                support.usage_event(int(now.timestamp() * 1000), {"outputTokens": 1_000_000}),
            ],
        )
        payload, _ = self._build_offline()
        self.assertAlmostEqual(payload["spend"]["today"], 3.0, places=4)
        self.assertAlmostEqual(payload["spend"]["window"], 3.0, places=4)
        self.assertAlmostEqual(payload["spend"]["total"], 5.0, places=4)

    def test_zstd_timeout_is_a_warning_not_a_hang(self):
        workspace = self.sessions / "ws"
        workspace.mkdir(parents=True)
        (workspace / "session.v4.jsonl.zstd").write_bytes(b"placeholder")
        script = self.tmp / "slow-zstd.sh"
        script.write_text("#!/bin/sh\nexec sleep 30\n", encoding="utf-8")
        script.chmod(0o755)

        with mock.patch.object(self.module, "ZSTD_BIN", str(script)), mock.patch.object(
            self.module, "ZSTD_TIMEOUT_SECONDS", 1
        ):
            started = time.time()
            payload, _ = self._build_offline()
            elapsed = time.time() - started

        self.assertLess(elapsed, 8.0, "解压超时没有生效：%.2fs" % elapsed)
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("解压超时" in item for item in payload["warnings"]), payload["warnings"])
        self.assertIsNone(payload["error"])

    # ---------- 余额 ----------

    def test_balance_official_source_with_mocked_network(self):
        opener = FakeOpener(response=FakeResponse(json.dumps(BALANCE_BODY).encode("utf-8")))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(key=FAKE_KEY)
        self.assertEqual(payload["balance"], {"amount": 88.5, "currency": "CNY", "source": "official"})
        self.assertEqual(len(opener.calls), 1)
        request, timeout = opener.calls[0]
        self.assertEqual(request.full_url, OFFICIAL_URL)
        self.assertEqual(request.get_header("Authorization"), "Bearer " + FAKE_KEY)
        self.assertLessEqual(timeout, 3.0)
        rendered = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn(FAKE_KEY, rendered)
        support.assert_no_secrets(self, rendered)

    def test_balance_prefers_cny_when_multiple_currencies(self):
        body = {
            "is_available": True,
            "balance_infos": [
                {"currency": "USD", "total_balance": "10.00"},
                {"currency": "CNY", "total_balance": "70.00"},
            ],
        }
        opener = FakeOpener(response=FakeResponse(json.dumps(body).encode("utf-8")))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(key=FAKE_KEY)
        self.assertEqual(payload["balance"], {"amount": 70.0, "currency": "CNY", "source": "official"})

    def test_balance_error_messages_are_human(self):
        cases = [
            (401, "API key 无效"),
            (429, "限流"),
            (500, "暂时不可用"),
            (302, "拒绝跟随"),
        ]
        for code, expected in cases:
            with self.subTest(code=code):
                opener = FakeOpener(exc=http_error(code))
                with mock.patch.object(self.module, "_OPENER", opener):
                    payload = self._build(key=FAKE_KEY)
                self.assertIsNone(payload["balance"])
                self.assertTrue(
                    any(expected in item for item in payload["warnings"]),
                    "code=%d warnings=%r" % (code, payload["warnings"]),
                )
                self.assertNotIn(FAKE_KEY, json.dumps(payload, ensure_ascii=False))

    def test_balance_bad_bodies_become_warnings(self):
        cases = [
            (json.dumps({"is_available": True, "balance_infos": []}).encode(), "没有返回余额明细"),
            (json.dumps({"balance_infos": [{"currency": "CNY"}]}).encode(), "可读的余额数字"),
            (b"<html>gateway</html>", "不是合法 JSON"),
        ]
        for body, expected in cases:
            with self.subTest(body=body[:20]):
                opener = FakeOpener(response=FakeResponse(body))
                with mock.patch.object(self.module, "_OPENER", opener):
                    payload = self._build(key=FAKE_KEY)
                self.assertIsNone(payload["balance"])
                self.assertTrue(any(expected in item for item in payload["warnings"]))

    def test_final_url_must_be_official(self):
        opener = FakeOpener(response=FakeResponse(json.dumps(BALANCE_BODY).encode("utf-8"),
                                                  final_url="http://evil.example/steal"))
        with mock.patch.object(self.module, "_OPENER", opener):
            payload = self._build(key=FAKE_KEY)
        self.assertIsNone(payload["balance"])
        self.assertTrue(any("官方域名" in item for item in payload["warnings"]))

    def test_is_official_url_unit(self):
        cases = {
            OFFICIAL_URL: True,
            "https://api.deepseek.com/user/balance?x=1": True,
            "http://api.deepseek.com/user/balance": False,
            "https://api.deepseek.com.evil.com/x": False,
            "https://evil.com/api.deepseek.com": False,
            "https://api.deepseek.com:8443/x": False,
            "https://api.deepseek.com@evil.com/x": False,
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(self.module.is_official_url(url), expected)

    def test_redirect_never_leaks_authorization(self):
        target = support.LocalServer(lambda path: (200, {}, b"{}"))
        source = support.LocalServer(
            lambda path: (302, {"Location": target.url + "/steal"}, b"")
        )
        self.addCleanup(target.close)
        self.addCleanup(source.close)
        try:
            with mock.patch.object(self.module, "BALANCE_URL", source.url + "/balance"):
                payload = self._build(key=FAKE_KEY)
        finally:
            pass

        self.assertIsNone(payload["balance"])
        self.assertTrue(
            any(("重定向" in item) or ("官方域名" in item) for item in payload["warnings"]),
            payload["warnings"],
        )
        # 关键断言：重定向目标一个请求都没收到，更没有 Authorization
        self.assertEqual(target.requests, [])
        self.assertEqual(len(source.requests), 1)
        self.assertIn("Authorization", source.requests[0][1])
        self.assertNotIn(FAKE_KEY, json.dumps(payload, ensure_ascii=False))

    def test_output_is_strict_json(self):
        completed = support.run_probe("deepseek", self.home)
        support.strict_loads(completed.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
