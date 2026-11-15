#!/usr/bin/env python3
"""Codex 探针验收：正常帧、选帧确定性、过期/陈旧、越界与 NaN、损坏日志、凭据泄露。

每个用例都在临时 HOME 里跑，绝不读真实 ~/.codex。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


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

    def test_same_mtime_picks_latest_frame_by_content(self):
        base = int(now_utc().timestamp()) - 3600
        older_ts = iso_ms(datetime.datetime.fromtimestamp(base - 600, datetime.timezone.utc))
        newer_ts = iso_ms(datetime.datetime.fromtimestamp(base, datetime.timezone.utc))
        # 文件名排序与内容新旧的顺序相反，验证不依赖目录枚举顺序
        self._rollout(
            "2026/11/10/rollout-a.jsonl",
            [support.token_count_line(11.0, 3.0, base + 600, base + 7200, timestamp=older_ts)],
            mtime=base,
        )
        self._rollout(
            "2026/11/10/rollout-b.jsonl",
            [support.token_count_line(22.0, 6.0, base + 600, base + 7200, timestamp=newer_ts)],
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
