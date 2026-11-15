#!/usr/bin/env python3
"""DeepSeek 探针验收：无窗口、余额（含无 key / 假网络）、tokenUsage.totals 估算、防泄露。

网络一律 mock，不打真实接口；HOME 全部临时隔离。
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
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

ZSTD = "/opt/homebrew/bin/zstd"
FAKE_KEY = "sk-test-1234567890abcdefghij"
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


def load_probe(name: str):
    path = support.PROBES / (name + ".py")
    spec = importlib.util.spec_from_file_location("usage_lens_probe_" + name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse:
    def __init__(self, body: bytes):
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False


def today_ms() -> int:
    now = datetime.datetime.now()
    return int(now.timestamp() * 1000)


def usage_event(ms: int, totals: dict) -> dict:
    return {"type": "token_usage", "seq": 1, "time": ms, "tokenUsage": {"totals": totals}}


class DeepSeekProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.sessions = self.home / ".dsh" / "sessions"

    def tearDown(self):
        self._tmp.cleanup()

    # ---------- 端到端（子进程） ----------

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
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))
        support.assert_no_secrets(self, completed.stderr.decode("utf-8"))

    def test_missing_dsh_dir_gives_spend_warning(self):
        shutil.rmtree(self.home / ".dsh")
        completed = support.run_probe("deepseek", self.home)
        self.assertEqual(completed.returncode, 0)
        payload = support.parse_stdout(completed)
        self.assertIsNone(payload["spend"])
        self.assertTrue(any(".dsh" in item for item in payload["warnings"]))

    def test_corrupt_session_archive_is_skipped_with_warning(self):
        workspace = self.sessions / "ws"
        workspace.mkdir(parents=True)
        (workspace / "session.v4.jsonl.zstd").write_bytes(b"this is not zstd at all")
        completed = support.run_probe("deepseek", self.home)
        self.assertEqual(completed.returncode, 0)
        payload = support.parse_stdout(completed)
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("解压" in item for item in payload["warnings"]))

    def test_windows_always_empty_no_fake_percent(self):
        completed = support.run_probe("deepseek", self.home, env_extra={"DEEPSEEK_API_KEY": ""})
        payload = support.parse_stdout(completed)
        self.assertEqual(payload["windows"], [])

    def test_unknown_argument_returns_json_error(self):
        completed = support.run_probe("deepseek", self.home, args=["--debug"])
        self.assertNotEqual(completed.returncode, 0)
        payload = support.parse_stdout(completed)
        self.assertIsNotNone(payload["error"])

    # ---------- 余额：进程内 + mock 网络 ----------

    def _probe(self):
        module = load_probe("deepseek")
        module.DSH_SESSIONS_DIR = self.sessions
        return module

    def _no_key_payload(self, module):
        with mock.patch.dict(os.environ, {"DEEPSEEK_API_KEY": ""}):
            return module.build_payload()

    def test_balance_official_source_with_mocked_network(self):
        module = self._probe()
        calls = []

        def fake_urlopen(request, timeout=None):
            calls.append((request, timeout))
            return FakeResponse(json.dumps(BALANCE_BODY).encode("utf-8"))

        with mock.patch.object(module.urlrequest, "urlopen", fake_urlopen):
            with mock.patch.dict(os.environ, {"DEEPSEEK_API_KEY": FAKE_KEY}):
                payload = module.build_payload()

        self.assertEqual(payload["balance"], {"amount": 88.5, "currency": "CNY", "source": "official"})
        self.assertEqual(len(calls), 1)
        request, timeout = calls[0]
        self.assertEqual(request.full_url, "https://api.deepseek.com/user/balance")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + FAKE_KEY)
        self.assertLessEqual(timeout, 3.0)
        rendered = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn(FAKE_KEY, rendered)
        support.assert_no_secrets(self, rendered)

    def test_balance_http_error_is_warning_not_crash(self):
        module = self._probe()

        def fake_urlopen(request, timeout=None):
            raise urllib.error.HTTPError(
                "https://api.deepseek.com/user/balance", 401, "Unauthorized", {}, None
            )

        with mock.patch.object(module.urlrequest, "urlopen", fake_urlopen):
            with mock.patch.dict(os.environ, {"DEEPSEEK_API_KEY": FAKE_KEY}):
                payload = module.build_payload()

        self.assertIsNone(payload["balance"])
        self.assertTrue(any("HTTP 401" in item for item in payload["warnings"]))
        self.assertNotIn(FAKE_KEY, json.dumps(payload, ensure_ascii=False))

    # ---------- 花费估算 ----------

    def _write_archive(self, events):
        self.assertIsNotNone(shutil.which("zstd") or os.path.isfile(ZSTD))
        workspace = self.sessions / "ws-1"
        workspace.mkdir(parents=True, exist_ok=True)
        raw = "".join(json.dumps(event, ensure_ascii=False) + "\n" for event in events).encode("utf-8")
        target = workspace / "session.v4.jsonl.zstd"
        completed = subprocess.run(
            [ZSTD, "-q", "-o", str(target)],
            input=raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        return target

    def test_spend_estimate_from_token_totals(self):
        self._write_archive(
            [
                {"type": "session", "version": 4, "id": "s1"},
                usage_event(
                    today_ms(),
                    {
                        "inputTokens": 1000000,
                        "cachedInputTokens": 500000,
                        "outputTokens": 100000,
                        "totalTokens": 1600000,
                    },
                ),
            ]
        )
        module = self._probe()
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DEEPSEEK_API_KEY", None)
            payload = module.build_payload()

        spend = payload["spend"]
        self.assertIsNotNone(spend)
        self.assertEqual(spend["currency"], "CNY")
        self.assertEqual(spend["source"], "estimate")
        # 0.5M 未命中输入 *2 + 0.5M 命中输入 *0.2 + 0.1M 输出 *3 = 1.4 元
        self.assertAlmostEqual(spend["today"], 1.4, places=4)
        self.assertAlmostEqual(spend["window"], 1.4, places=4)
        today = datetime.date.today().isoformat()
        self.assertEqual(payload["coverage"]["from"], today)
        self.assertEqual(payload["coverage"]["to"], today)
        self.assertTrue(any("牌价" in item for item in payload["warnings"]))
        self.assertEqual(payload["windows"], [])

    def test_spend_prefers_explicit_cost_field(self):
        self._write_archive(
            [
                usage_event(
                    today_ms(),
                    {"inputTokens": 10, "outputTokens": 5, "totalCost": 2.25, "currency": "CNY"},
                ),
            ]
        )
        module = self._probe()
        with mock.patch.object(module.urlrequest, "urlopen", mock.Mock(side_effect=AssertionError("no network"))):
            payload = self._no_key_payload(module)
        self.assertAlmostEqual(payload["spend"]["today"], 2.25, places=4)
        self.assertFalse(any("牌价" in item for item in payload["warnings"]))

    def test_spend_aggregates_multiple_days(self):
        now = datetime.datetime.now()
        yesterday = now - datetime.timedelta(days=1)
        self._write_archive(
            [
                usage_event(
                    int(yesterday.timestamp() * 1000),
                    {"inputTokens": 1000000, "outputTokens": 0},
                ),
                usage_event(
                    int(now.timestamp() * 1000),
                    {"inputTokens": 0, "outputTokens": 1000000},
                ),
            ]
        )
        module = self._probe()
        payload = self._no_key_payload(module)
        self.assertAlmostEqual(payload["spend"]["today"], 3.0, places=4)
        self.assertAlmostEqual(payload["spend"]["window"], 5.0, places=4)

    def test_session_without_totals_gives_null_spend(self):
        self._write_archive([{"type": "session", "version": 4, "id": "s1"}])
        module = self._probe()
        payload = self._no_key_payload(module)
        self.assertIsNone(payload["spend"])
        self.assertIsNone(payload["coverage"])
        self.assertTrue(any("token 用量" in item for item in payload["warnings"]))

    def test_missing_zstd_gives_warning(self):
        self._write_archive([usage_event(today_ms(), {"outputTokens": 1000})])
        module = self._probe()
        with mock.patch.object(module, "ZSTD_BIN", "/nonexistent/zstd"), mock.patch.object(
            module.shutil, "which", return_value=None
        ):
            payload = self._no_key_payload(module)
        self.assertIsNone(payload["spend"])
        self.assertTrue(any("zstd" in item for item in payload["warnings"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
