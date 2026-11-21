#!/usr/bin/env python3
"""Codex 探针验收：正常帧、选帧确定性、过期/陈旧、越界与 NaN、损坏日志、凭据泄露。

每个用例都在临时 HOME 里跑，绝不读真实 ~/.codex。
"""

from __future__ import annotations

import base64
import datetime
import importlib.util
import io
import json
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"


def _make_fake_jwt(claims: dict) -> str:
    header = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').decode("ascii").rstrip("=")
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode("utf-8")).decode("ascii").rstrip("=")
    return "%s.%s.fakesig_test_only_12345" % (header, payload)


def _load_codex_probe():
    path = support.PROBES / "codex.py"
    spec = importlib.util.spec_from_file_location("probe_codex_under_test", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _FakeResponse:
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


class _FakeOpener:
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


def now_utc() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_ms(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123Z")


def epoch_iso(seconds: int) -> str:
    return iso(datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc))


class CodexProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.sessions = self.home / ".codex" / "sessions"

    def tearDown(self):
        self._tmp.cleanup()

    def _rollout(self, relpath: str, lines, mtime: float):
        path = support.write_rollout(self.sessions / relpath, lines, mtime=int(mtime))
        return path

    def _run(self):
        completed = support.run_probe("codex", self.home)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        payload = support.parse_stdout(completed)
        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertRegex(payload["generated_at"], ISO_RE)
        self.assertRegex(payload["observed_at"], ISO_RE)
        self.assertIsInstance(payload["stale"], bool)
        self.assertIsNone(payload["error"])
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))
        return completed, payload

    # ---------- 正常帧与契约 ----------

    def test_normal_fixture_last_frame_and_contract(self):
        moment = now_utc() - datetime.timedelta(seconds=60)
        resets_primary = int(now_utc().timestamp()) + 3600
        resets_secondary = int(now_utc().timestamp()) + 86400
        self._rollout(
            "2026/11/01/rollout-old.jsonl",
            [support.token_count_line(41.0, 22.0, resets_primary, resets_secondary, plan="pro")],
            mtime=moment.timestamp() - 7200,
        )
        frame_ts = iso_ms(moment)
        self._rollout(
            "2026/11/10/rollout-new.jsonl",
            [
                support.token_count_line(35.0, 14.0, resets_primary, resets_secondary,
                                         timestamp=iso_ms(moment - datetime.timedelta(seconds=30))),
                support.token_count_line(21.0, 18.0, resets_primary, resets_secondary,
                                         timestamp=frame_ts),
            ],
            mtime=moment.timestamp(),
        )

        _, payload = self._run()
        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(payload["account"], {"label": None, "plan": "plus"})
        self.assertEqual(payload["observed_at"], iso(moment)[:19] + "Z")
        self.assertFalse(payload["stale"])
        self.assertEqual(len(payload["windows"]), 2)

        primary, secondary = payload["windows"]
        self.assertEqual(set(primary), support.WINDOW_KEYS)
        self.assertEqual(primary, {
            "id": "5h",
            "label": "5 小时",
            "used_percent": 21.0,
            "window_seconds": 18000,
            "resets_at": epoch_iso(resets_primary),
            "expired": False,
            "basis": "server",
        })
        self.assertEqual(secondary, {
            "id": "7d",
            "label": "7 天",
            "used_percent": 18.0,
            "window_seconds": 604800,
            "resets_at": epoch_iso(resets_secondary),
            "expired": False,
            "basis": "server",
        })
        self.assertEqual(payload["coverage"]["from"], payload["observed_at"][:10])
        self.assertEqual(payload["coverage"]["to"], payload["observed_at"][:10])
        self.assertEqual(payload["warnings"], [])

    def test_today_tokens_are_locally_aggregated(self):
        moment = now_utc() - datetime.timedelta(seconds=30)
        resets = int(now_utc().timestamp()) + 3600
        self._rollout(
            "2026/11/15/rollout-tokens.jsonl",
            [
                support.token_usage_record_line(120, iso_ms(moment - datetime.timedelta(minutes=2))),
                support.token_usage_record_line(80, iso_ms(moment), current_shape=True),
                support.token_usage_record_line(999, iso_ms(moment - datetime.timedelta(days=1))),
                support.token_count_line(21, 18, resets, resets + 86400, timestamp=iso_ms(moment)),
            ],
            mtime=moment.timestamp(),
        )
        _, payload = self._run()
        self.assertEqual(payload["usage"], {"today_tokens": 200, "source": "local"})

    def test_expired_windows_get_flag_and_warning(self):
        moment = now_utc() - datetime.timedelta(days=4)
        resets_primary = int(moment.timestamp()) + 7200
        resets_secondary = int(moment.timestamp()) + 86400
        self._rollout(
            "2026/11/10/rollout-test.jsonl",
            [support.token_count_line(21.0, 18.0, resets_primary, resets_secondary,
                                      timestamp=iso_ms(moment))],
            mtime=moment.timestamp(),
        )
        _, payload = self._run()
        self.assertTrue(payload["windows"][0]["expired"])
        self.assertTrue(payload["windows"][1]["expired"])
        self.assertTrue(payload["stale"])
        self.assertTrue(any("重置" in item for item in payload["warnings"]))
        self.assertTrue(any("数据来自" in item for item in payload["warnings"]))
        self.assertTrue(any("可能不是当前状态" in item for item in payload["warnings"]))

    def test_stale_when_observed_older_than_window(self):
        moment = now_utc() - datetime.timedelta(days=10)
        # 重置时间在未来：没有 expired，但数据很旧 -> stale
        resets_primary = int(now_utc().timestamp()) + 86400
        resets_secondary = int(now_utc().timestamp()) + 864000
        self._rollout(
            "2026/11/10/rollout-test.jsonl",
            [support.token_count_line(3.0, 1.0, resets_primary, resets_secondary,
                                      timestamp=iso_ms(moment))],
            mtime=moment.timestamp(),
        )
        _, payload = self._run()
        self.assertFalse(payload["windows"][0]["expired"])
        self.assertTrue(payload["stale"])
        self.assertTrue(any("数据来自" in item for item in payload["warnings"]))

    def test_same_mtime_uses_content_timestamp_in_both_orders(self):
        base = int(now_utc().timestamp()) - 3600
        older_ts = iso_ms(datetime.datetime.fromtimestamp(base - 600, datetime.timezone.utc))
        newer_ts = iso_ms(datetime.datetime.fromtimestamp(base, datetime.timezone.utc))

        # 两种「扫描顺序 vs 内容新旧」组合都要对：
        #   A: 旧内容的文件先被扫到 -> 只取第一个命中的实现会拿到 11.0，必须失败
        #   B: 新内容的文件先被扫到 -> 只取第一个命中的实现碰巧能过
        # 只有真去比帧时间戳的实现，两版都过。
        scenarios = {
            "A_枚举先旧后新": [
                ("2026/11/10/rollout-z-old.jsonl", 11.0, older_ts),
                ("2026/11/10/rollout-a-new.jsonl", 22.0, newer_ts),
            ],
            "B_枚举先新后旧": [
                ("2026/11/11/rollout-a-old.jsonl", 11.0, older_ts),
                ("2026/11/11/rollout-z-new.jsonl", 22.0, newer_ts),
            ],
        }
        for label, files in scenarios.items():
            with self.subTest(scenario=label):
                shutil.rmtree(self.sessions)
                for relpath, percent, timestamp in files:
                    self._rollout(
                        relpath,
                        [support.token_count_line(percent, 3.0, base + 600, base + 7200,
                                                  timestamp=timestamp)],
                        mtime=base,
                    )
                for _ in range(2):
                    _, payload = self._run()
                    self.assertEqual(payload["observed_at"], newer_ts[:19] + "Z")
                    self.assertEqual(payload["windows"][0]["used_percent"], 22.0)

    def test_skips_newest_file_without_rate_limits(self):
        moment = now_utc() - datetime.timedelta(seconds=30)
        self._rollout(
            "2026/11/05/rollout-has-limits.jsonl",
            [support.token_count_line(44.0, 33.0, int(moment.timestamp()) + 3600,
                                      int(moment.timestamp()) + 86400,
                                      timestamp=iso_ms(moment - datetime.timedelta(minutes=10)))],
            mtime=moment.timestamp() - 3600,
        )
        self._rollout(
            "2026/11/10/rollout-no-limits.jsonl",
            [
                json.dumps({"timestamp": iso_ms(moment), "type": "turn_context",
                            "payload": {"model": "gpt-5-codex", "cwd": "/tmp"}}),
                support.token_count_line(0, 0, 0, 0, with_rate_limits=False),
            ],
            mtime=moment.timestamp(),
        )

        _, payload = self._run()
        self.assertEqual([w["used_percent"] for w in payload["windows"]], [44.0, 33.0])

    # ---------- 降级与损坏 ----------

    def test_empty_sessions_dir_exits_zero_with_warning(self):
        _, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("没有 rollout" in item for item in payload["warnings"]))
        self.assertEqual(payload["observed_at"], payload["generated_at"])
        self.assertIsNone(payload["coverage"])
        self.assertFalse(payload["stale"])

    def test_missing_sessions_dir_exits_zero_with_warning(self):
        shutil.rmtree(self.home / ".codex")
        _, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("~/.codex/sessions" in item for item in payload["warnings"]))
        self.assertIsNone(payload["coverage"])

    def test_log_without_rate_limits_exits_zero_with_warning(self):
        self._rollout(
            "2026/11/10/rollout-plain.jsonl",
            [
                support.token_count_line(0, 0, 0, 0, with_rate_limits=False),
                json.dumps({"timestamp": "2026-11-11T02:00:00.000Z", "type": "response_item",
                            "payload": {"type": "message"}}),
            ],
            mtime=int(now_utc().timestamp()),
        )
        _, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("rate_limits" in item for item in payload["warnings"]))

    def test_corrupt_lines_do_not_crash(self):
        self._rollout(
            "2026/11/10/rollout-broken.jsonl",
            [
                '{"broken json...',
                "not json at all",
                '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"prim',
            ],
            mtime=int(now_utc().timestamp()),
        )
        _, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("无法解析" in item for item in payload["warnings"]))

    def test_corrupt_lines_after_valid_frame_are_skipped(self):
        moment = now_utc() - datetime.timedelta(seconds=30)
        self._rollout(
            "2026/11/10/rollout-mixed.jsonl",
            [
                support.token_count_line(12.5, 6.0, int(moment.timestamp()) + 3600,
                                         int(moment.timestamp()) + 86400, timestamp=iso_ms(moment)),
                "{oops",
            ],
            mtime=moment.timestamp(),
        )
        _, payload = self._run()
        self.assertEqual(payload["windows"][0]["used_percent"], 12.5)

    # ---------- 数值边界 ----------

    def test_used_percent_missing_is_null_not_zero(self):
        line = json.dumps({
            "timestamp": "2026-11-11T02:00:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "rate_limits": {
                    "primary": {"window_minutes": 300, "resets_at": int(now_utc().timestamp()) + 60},
                    "secondary": {"window_minutes": 10080,
                                  "resets_at": int(now_utc().timestamp()) + 86400},
                    "plan_type": "plus",
                },
            },
        })
        self._rollout("2026/11/10/rollout-no-percent.jsonl", [line], mtime=now_utc().timestamp())
        _, payload = self._run()
        self.assertIsNone(payload["windows"][0]["used_percent"])
        self.assertIsNone(payload["windows"][1]["used_percent"])

    def test_out_of_range_used_percent_becomes_null_with_warning(self):
        resets = int(now_utc().timestamp()) + 3600
        self._rollout(
            "2026/11/10/rollout-range.jsonl",
            [
                support.token_count_line(150.0, -5.0, resets, resets + 86400,
                                         timestamp="2026-11-11T02:00:00.000Z"),
            ],
            mtime=now_utc().timestamp(),
        )
        _, payload = self._run()
        self.assertIsNone(payload["windows"][0]["used_percent"])
        self.assertIsNone(payload["windows"][1]["used_percent"])
        self.assertTrue(any("数值异常" in item for item in payload["warnings"]))

    def test_nan_used_percent_is_null_and_output_is_strict_json(self):
        resets = int(now_utc().timestamp()) + 3600
        line = (
            '{"timestamp":"2026-11-11T02:00:00.000Z","type":"event_msg",'
            '"payload":{"type":"token_count","rate_limits":{"primary":'
            '{"used_percent":NaN,"window_minutes":300,"resets_at":%d},'
            '"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":%d}}}}'
        ) % (resets, resets + 86400)
        self._rollout("2026/11/10/rollout-nan.jsonl", [line], mtime=now_utc().timestamp())

        completed, payload = self._run()
        self.assertIsNone(payload["windows"][0]["used_percent"])
        self.assertTrue(any("数值异常" in item for item in payload["warnings"]))
        # parse_stdout 用的是严格 JSON（拒绝 NaN），能走到这里就说明 stdout 合法
        support.strict_loads(completed.stdout.decode("utf-8"))

    def test_window_minutes_mapping_and_fallback(self):
        base = int(now_utc().timestamp())
        line = json.dumps({
            "timestamp": "2026-11-11T02:00:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "rate_limits": {
                    "primary": {"used_percent": 10.0, "window_minutes": 60, "resets_at": base + 3600},
                    "secondary": {"used_percent": 20.0, "resets_at": base + 86400},
                },
            },
        })
        self._rollout("2026/11/10/rollout-minutes.jsonl", [line], mtime=base)
        _, payload = self._run()
        self.assertEqual(payload["windows"][0]["window_seconds"], 3600)
        self.assertEqual(payload["windows"][1]["window_seconds"], 604800)

    def test_boolean_resets_at_is_ignored(self):
        base = int(now_utc().timestamp())
        line = json.dumps({
            "timestamp": "2026-11-11T02:00:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "rate_limits": {
                    "primary": {"used_percent": 10.0, "window_minutes": 300, "resets_at": True},
                    "secondary": {"used_percent": 20.0, "window_minutes": 10080, "resets_at": base + 86400},
                },
            },
        })
        self._rollout("2026/11/10/rollout-boolean.jsonl", [line], mtime=base)
        _, payload = self._run()
        self.assertIsNone(payload["windows"][0]["resets_at"])
        self.assertFalse(payload["windows"][0]["expired"])

    # ---------- 扫描性能与截断 ----------

    def test_large_log_scans_tail_fast(self):
        moment = now_utc() - datetime.timedelta(seconds=30)
        filler = json.dumps({"type": "response_item",
                             "payload": {"type": "message", "text": "x" * 400}})
        lines = [filler] * 18000
        lines.append(support.token_count_line(67.0, 5.5, int(moment.timestamp()) + 3600,
                                              int(moment.timestamp()) + 86400,
                                              timestamp=iso_ms(moment)))
        path = self._rollout("2026/11/10/rollout-big.jsonl", lines, mtime=moment.timestamp())
        self.assertGreater(path.stat().st_size, 7 * 1024 * 1024)

        started = time.time()
        completed = support.run_probe("codex", self.home)
        elapsed = time.time() - started
        self.assertEqual(completed.returncode, 0)
        payload = support.parse_stdout(completed)
        self.assertEqual(payload["windows"][0]["used_percent"], 67.0)
        self.assertLess(elapsed, 3.0, "大日志下探针太慢：%.2fs" % elapsed)

    def test_oversized_log_gives_truncated_scan_warning(self):
        moment = now_utc() - datetime.timedelta(seconds=30)
        # 有效帧在最前面，后面是 >4MB 填充：回扫上限内找不到，必须给 warning 而不是瞎猜
        lines = [support.token_count_line(67.0, 5.5, int(moment.timestamp()) + 3600,
                                          int(moment.timestamp()) + 86400,
                                          timestamp=iso_ms(moment))]
        lines.extend(json.dumps({"type": "response_item",
                                 "payload": {"type": "message", "text": "y" * 400}})
                     for _ in range(12000))
        path = self._rollout("2026/11/10/rollout-huge.jsonl", lines, mtime=moment.timestamp())
        self.assertGreater(path.stat().st_size, 4 * 1024 * 1024)

        _, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("超过 4MB" in item for item in payload["warnings"]))

    # ---------- 参数 ----------

    def test_json_flag_accepted(self):
        base = int(now_utc().timestamp())
        self._rollout(
            "2026/11/10/rollout-test.jsonl",
            [support.token_count_line(3.0, 1.0, base + 3600, base + 86400)],
            mtime=base,
        )
        completed = support.run_probe("codex", self.home, args=["--json"])
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(support.parse_stdout(completed)["provider"], "codex")

    def test_unknown_argument_returns_exit_2_and_single_json_line(self):
        completed = support.run_probe("codex", self.home, args=["--verbose"])
        self.assertEqual(completed.returncode, 2)
        payload = support.parse_stdout(completed)
        self.assertIn("不支持的参数", payload["error"])
        self.assertEqual(payload["windows"], [])


class CodexLiveServerTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.sessions = self.home / ".codex" / "sessions"
        self.auth_file = self.home / ".codex" / "auth.json"
        self.module = _load_codex_probe()
        self.module.SESSIONS_DIR = self.sessions
        self.module.AUTH_FILE = self.auth_file
        self.fake_access = _make_fake_jwt({"sub": "user-1", "scope": "model.read"})
        self.fake_id = _make_fake_jwt({
            "email": "codex.user@example.com",
            "https://api.openai.com/auth": {
                "chatgpt_account_id": "acct-from-claim-123",
                "chatgpt_plan_type": "plus",
            },
        })

    def tearDown(self):
        self._tmp.cleanup()

    def _write_auth(self, account_id: str = "acct-uuid-999"):
        self.auth_file.parent.mkdir(parents=True, exist_ok=True)
        self.auth_file.write_text(
            json.dumps({
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": self.fake_access,
                    "id_token": self.fake_id,
                    "refresh_token": "rt_synthetic_refresh_token_test_only",
                    "account_id": account_id,
                },
            }),
            encoding="utf-8",
        )

    def _write_local_fallback_log(self, primary_pct=41.0, secondary_pct=22.0, today_tokens=250):
        moment = now_utc() - datetime.timedelta(seconds=30)
        resets = int(now_utc().timestamp()) + 3600
        lines = [
            support.token_usage_record_line(today_tokens, iso_ms(moment), current_shape=True),
            support.token_count_line(primary_pct, secondary_pct, resets, resets + 86400, timestamp=iso_ms(moment)),
        ]
        support.write_rollout(
            self.sessions / "2026/11/21/rollout-local.jsonl",
            lines,
            mtime=int(moment.timestamp()),
        )

    def _clean_env(self, extra=None):
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("CODEX_ACCESS_TOKEN", "CODEX_ACCOUNT_ID", "CODEX_ACCOUNT_EMAIL")
        }
        env["HOME"] = str(self.home)
        if extra:
            env.update(extra)
        return env

    def test_live_200_success_returns_realtime_windows_account_and_today_tokens(self):
        self._write_auth()
        self._write_local_fallback_log(primary_pct=99.0, secondary_pct=88.0, today_tokens=321)
        before = support.fingerprint(self.home)

        reset_5h = int(now_utc().timestamp()) + 7200
        reset_7d = int(now_utc().timestamp()) + 5 * 86400
        live_body = json.dumps({
            "plan_type": "pro",
            "rate_limit": {
                "allowed": True,
                "limit_reached": False,
                "primary_window": {
                    "used_percent": 15.5,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 7200,
                    "reset_at": reset_5h,
                },
                "secondary_window": {
                    "used_percent": 12.0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 5 * 86400,
                    "reset_at": reset_7d,
                },
            },
        }).encode("utf-8")

        opener = _FakeOpener(responses=[_FakeResponse(live_body, CODEX_USAGE_URL)])
        with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
             mock.patch.object(self.module, "_OPENER", opener):
            payload = self.module.build_payload()

        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertIsNone(payload["error"])
        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(payload["account"], {"label": "codex.user@example.com", "plan": "pro"})
        self.assertEqual(payload["observed_at"], payload["generated_at"])
        self.assertFalse(payload["stale"])
        self.assertIsNone(payload["coverage"])
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(payload["usage"], {"today_tokens": 321, "source": "local"})
        self.assertEqual(len(payload["windows"]), 2)
        self.assertEqual(payload["windows"][0]["id"], "5h")
        self.assertEqual(payload["windows"][0]["used_percent"], 15.5)
        self.assertEqual(payload["windows"][0]["resets_at"], epoch_iso(reset_5h))
        self.assertEqual(payload["windows"][1]["id"], "7d")
        self.assertEqual(payload["windows"][1]["used_percent"], 12.0)
        self.assertEqual(payload["windows"][1]["resets_at"], epoch_iso(reset_7d))

        self.assertEqual(len(opener.calls), 1)
        req, timeout = opener.calls[0]
        self.assertEqual(req.full_url, CODEX_USAGE_URL)
        self.assertEqual(req.get_header("Authorization"), "Bearer " + self.fake_access)
        self.assertEqual(req.get_header("Chatgpt-account-id"), "acct-uuid-999")
        self.assertLessEqual(timeout, 3.0)

        rendered = json.dumps(payload, ensure_ascii=False, allow_nan=False)
        self.assertNotIn(self.fake_access, rendered)
        self.assertNotIn(self.fake_id, rendered)
        support.assert_no_secrets(self, rendered)
        self.assertEqual(support.fingerprint(self.home), before)

    def test_live_invalid_nan_and_expired_values_stay_strict_json(self):
        self._write_auth()
        past_reset = int(now_utc().timestamp()) - 1800
        live_body = (
            '{"plan_type":"plus","rate_limit":{"primary_window":'
            '{"used_percent":NaN,"limit_window_seconds":18000,"reset_at":%d},'
            '"secondary_window":{"used_percent":150,"limit_window_seconds":604800,"reset_after_seconds":3600}}}'
        ) % past_reset
        opener = _FakeOpener(responses=[_FakeResponse(live_body.encode("utf-8"), CODEX_USAGE_URL)])
        with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
             mock.patch.object(self.module, "_OPENER", opener):
            payload = self.module.build_payload()

        strict_text = json.dumps(payload, ensure_ascii=False, allow_nan=False)
        parsed = support.strict_loads(strict_text)
        self.assertIsNone(parsed["windows"][0]["used_percent"])
        self.assertTrue(parsed["windows"][0]["expired"])
        self.assertIsNone(parsed["windows"][1]["used_percent"])
        self.assertFalse(parsed["windows"][1]["expired"])
        self.assertTrue(any("数值异常" in w for w in parsed["warnings"]))
        self.assertTrue(any("重置" in w for w in parsed["warnings"]))

    def test_live_failures_gracefully_fallback_to_local_logs(self):
        self._write_auth()
        self._write_local_fallback_log(primary_pct=41.0, secondary_pct=22.0, today_tokens=180)
        before = support.fingerprint(self.home)

        cases = [
            ("http_401", _FakeOpener(exc=urllib.error.HTTPError(CODEX_USAGE_URL, 401, "unauth", {}, None)), "401"),
            ("http_403", _FakeOpener(exc=urllib.error.HTTPError(CODEX_USAGE_URL, 403, "forbid", {}, None)), "403"),
            ("http_429", _FakeOpener(exc=urllib.error.HTTPError(CODEX_USAGE_URL, 429, "limit", {}, None)), "限流"),
            ("http_500", _FakeOpener(exc=urllib.error.HTTPError(CODEX_USAGE_URL, 500, "err", {}, None)), "500"),
            ("timeout", _FakeOpener(exc=TimeoutError("timed out")), "超时"),
            ("malformed", _FakeOpener(responses=[_FakeResponse(b"<html>bad</html>", CODEX_USAGE_URL)]), "合法 JSON"),
            (
                "oversized",
                _FakeOpener(responses=[_FakeResponse(b"{}", CODEX_USAGE_URL, headers={"Content-Length": str(2 * 1024 * 1024)})]),
                "过大",
            ),
            ("non_official", _FakeOpener(responses=[_FakeResponse(b"{}", "https://evil.example/wham")]), "官方域名"),
            ("empty_windows", _FakeOpener(responses=[_FakeResponse(b'{"rate_limit":{}}', CODEX_USAGE_URL)]), "未返回配额窗口"),
        ]

        for label, opener, expected_fragment in cases:
            with self.subTest(case=label):
                stdout_buf = io.StringIO()
                stderr_buf = io.StringIO()
                with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
                     mock.patch.object(self.module, "_OPENER", opener), \
                     mock.patch.object(sys, "stdout", stdout_buf), \
                     mock.patch.object(sys, "stderr", stderr_buf):
                    rc = self.module.main(["codex.py"])

                self.assertEqual(rc, 0)
                payload = support.strict_loads(stdout_buf.getvalue().strip())
                self.assertIsNone(payload["error"])
                self.assertEqual([w["used_percent"] for w in payload["windows"]], [41.0, 22.0])
                self.assertEqual(payload["account"]["label"], "codex.user@example.com")
                self.assertEqual(payload["usage"], {"today_tokens": 180, "source": "local"})
                self.assertTrue(
                    any("回退到本地会话日志" in w and expected_fragment in w for w in payload["warnings"]),
                    payload["warnings"],
                )
                self.assertNotIn(self.fake_access, stdout_buf.getvalue())
                self.assertNotIn(self.fake_access, stderr_buf.getvalue())
                support.assert_no_secrets(self, stdout_buf.getvalue())

        self.assertEqual(support.fingerprint(self.home), before)

    def test_live_failure_with_empty_local_logs_exits_zero_with_both_warnings(self):
        self._write_auth()
        opener = _FakeOpener(exc=urllib.error.HTTPError(CODEX_USAGE_URL, 401, "unauth", {}, None))
        with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
             mock.patch.object(self.module, "_OPENER", opener):
            payload = self.module.build_payload()

        self.assertIsNone(payload["error"])
        self.assertEqual(payload["windows"], [])
        self.assertTrue(any("回退到本地会话日志" in w for w in payload["warnings"]))
        self.assertTrue(any("没有 rollout" in w for w in payload["warnings"]))

    def test_redirect_refused_and_never_leaks_headers(self):
        self._write_auth()
        self._write_local_fallback_log(primary_pct=33.0, secondary_pct=19.0)
        target = support.LocalServer(lambda path: (200, {}, b"{}"))
        source = support.LocalServer(lambda path: (302, {"Location": target.url + "/steal"}, b""))
        self.addCleanup(target.close)
        self.addCleanup(source.close)

        with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
             mock.patch.object(self.module, "CODEX_USAGE_URL", source.url + "/wham/usage"):
            payload = self.module.build_payload()

        self.assertEqual(target.requests, [], "重定向目标绝不能收到任何请求")
        self.assertEqual(len(source.requests), 1)
        self.assertEqual([w["used_percent"] for w in payload["windows"]], [33.0, 19.0])
        self.assertTrue(
            any(("拒绝跟随" in w or "官方域名" in w) and "回退到本地会话日志" in w for w in payload["warnings"]),
            payload["warnings"],
        )
        self.assertNotIn(self.fake_access, json.dumps(payload, ensure_ascii=False))

    def test_is_official_url_unit(self):
        cases = {
            CODEX_USAGE_URL: True,
            "https://chatgpt.com:443/backend-api/wham/usage": True,
            "http://chatgpt.com/backend-api/wham/usage": False,
            "https://chatgpt.com.evil.com/backend-api/wham/usage": False,
            "https://evil.com/chatgpt.com": False,
            "https://chatgpt.com:8443/backend-api/wham/usage": False,
            "https://chatgpt.com@evil.com/backend-api/wham/usage": False,
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(self.module.is_official_url(url), expected)

    def test_secret_redaction_strips_jwt_bearer_sk_and_google_tokens_across_channels(self):
        google_access_short = "ya29.synthetic.short.token"
        google_access_long = "ya29.a0.segmented.access_token-12345"
        google_refresh = "1//syntheticRefresh1234"
        google_refresh_seg = "1//0e.segmented.refresh_token-5678"
        sk_token = "sk-secret123456"
        leaked = (
            "err %s Bearer %s %s %s %s %s %s"
            % (
                self.fake_access,
                self.fake_access,
                sk_token,
                google_access_short,
                google_access_long,
                google_refresh,
                google_refresh_seg,
            )
        )
        forbidden = (
            self.fake_access,
            sk_token,
            google_access_short,
            google_access_long,
            google_refresh,
            google_refresh_seg,
            "ya29.",
            "1//",
        )

        # 1. Live URLError fallback path -> emitted JSON warnings + stderr
        opener = _FakeOpener(exc=urllib.error.URLError(leaked))
        self._write_auth()
        self._write_local_fallback_log()
        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()
        with mock.patch.dict(os.environ, self._clean_env(), clear=True), \
             mock.patch.object(self.module, "_OPENER", opener), \
             mock.patch.object(sys, "stdout", stdout_buf), \
             mock.patch.object(sys, "stderr", stderr_buf):
            rc = self.module.main(["codex.py"])
            self.module._log(leaked)

        self.assertEqual(rc, 0)
        stdout_text = stdout_buf.getvalue()
        stderr_text = stderr_buf.getvalue()
        payload = support.strict_loads(stdout_text.strip())
        self.assertTrue(any("回退到本地会话日志" in w for w in payload["warnings"]), payload["warnings"])
        self.assertIn("[redacted]", stdout_text)
        self.assertIn("[redacted]", stderr_text)
        for secret in forbidden:
            self.assertNotIn(secret, stdout_text)
            self.assertNotIn(secret, stderr_text)
        support.assert_no_secrets(self, stdout_text)
        support.assert_no_secrets(self, stderr_text)

        # 2. Top-level error path -> emitted JSON error + stderr
        err_stdout = io.StringIO()
        err_stderr = io.StringIO()
        with mock.patch.object(self.module, "build_payload", side_effect=RuntimeError(leaked)), \
             mock.patch.object(sys, "stdout", err_stdout), \
             mock.patch.object(sys, "stderr", err_stderr):
            err_rc = self.module.main(["codex.py"])

        self.assertEqual(err_rc, 1)
        err_text = err_stdout.getvalue()
        err_payload = support.strict_loads(err_text.strip())
        self.assertIsNotNone(err_payload["error"])
        self.assertIn("[redacted]", err_payload["error"])
        for secret in forbidden:
            self.assertNotIn(secret, err_text)
        support.assert_no_secrets(self, err_text)

        # 3. Unsupported CLI argument path -> emitted JSON error + stderr
        arg_stdout = io.StringIO()
        arg_stderr = io.StringIO()
        with mock.patch.object(sys, "stdout", arg_stdout), \
             mock.patch.object(sys, "stderr", arg_stderr):
            arg_rc = self.module.main(["codex.py", "--token=" + google_access_short])

        self.assertEqual(arg_rc, 2)
        for text in (arg_stdout.getvalue(), arg_stderr.getvalue()):
            self.assertIn("[redacted]", text)
            self.assertNotIn(google_access_short, text)
            self.assertNotIn("ya29.", text)
            support.assert_no_secrets(self, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
