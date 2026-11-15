#!/usr/bin/env python3
"""Codex 探针验收：正常帧、损坏日志、空目录、窗口契约、凭据泄露。

每个用例都在临时 HOME 里跑，绝不读真实 ~/.codex。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def epoch_iso(seconds: int) -> str:
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


class CodexProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.sessions = self.home / ".codex" / "sessions"

    def tearDown(self):
        self._tmp.cleanup()

    def _rollout(self, relpath: str, lines, mtime: int):
        path = support.write_rollout(self.sessions / relpath, lines)
        os.utime(path, (mtime, mtime))
        return path

    def _run(self):
        completed = support.run_probe("codex", self.home)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        return completed, support.parse_stdout(completed)

    def test_normal_fixture_uses_last_frame_of_newest_file(self):
        older = "2026/11/01/rollout-old.jsonl"
        newer = "2026/11/10/rollout-new.jsonl"
        self._rollout(
            older,
            [
                support.token_count_line(41.0, 22.0, 1794374936, 1794488131, plan="pro"),
            ],
            mtime=1794000000,
        )
        self._rollout(
            newer,
            [
                support.token_count_line(35.0, 14.0, 1794327589, 1794488130),
                support.token_count_line(21.0, 18.0, 1794374936, 1794488131),
            ],
            mtime=1794300000,
        )

        completed, payload = self._run()
        self.assertEqual(payload["schema"], "usage-lens/probe@1")
        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertIsNone(payload["error"])
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(len(payload["windows"]), 2)

        primary, secondary = payload["windows"]
        self.assertEqual(primary["id"], "5h")
        self.assertEqual(primary["window_seconds"], 18000)
        self.assertEqual(primary["label"], "5 小时")
        self.assertEqual(primary["used_percent"], 21.0)
        self.assertEqual(primary["basis"], "server")
        self.assertEqual(primary["resets_at"], epoch_iso(1794374936))

        self.assertEqual(secondary["id"], "7d")
        self.assertEqual(secondary["window_seconds"], 604800)
        self.assertEqual(secondary["label"], "7 天")
        self.assertEqual(secondary["used_percent"], 18.0)
        self.assertEqual(secondary["basis"], "server")
        self.assertEqual(secondary["resets_at"], epoch_iso(1794488131))

        self.assertEqual(payload["account"], {"label": None, "plan": "plus"})
        self.assertIsNone(payload["balance"])
        self.assertIsNone(payload["spend"])
        self.assertRegex(payload["generated_at"], ISO_RE)

        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))

    def test_skips_newest_file_without_rate_limits(self):
        self._rollout(
            "2026/11/05/rollout-has-limits.jsonl",
            [support.token_count_line(44.0, 33.0, 1794374936, 1794488131)],
            mtime=1794000000,
        )
        # 更新但只有 turn_context，没有 rate_limits
        self._rollout(
            "2026/11/10/rollout-no-limits.jsonl",
            [
                json.dumps({"timestamp": "2026-11-11T02:00:00.000Z", "type": "turn_context",
                            "payload": {"model": "gpt-5-codex", "cwd": "/tmp"}}),
                support.token_count_line(0.0, 0.0, 0, 0, with_rate_limits=False),
            ],
            mtime=1794200000,
        )

        _, payload = self._run()
        self.assertEqual([w["used_percent"] for w in payload["windows"]], [44.0, 33.0])
        self.assertIsNone(payload["error"])

    def test_empty_sessions_dir_exits_zero_with_warning(self):
        completed, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(payload["warnings"])
        self.assertIsNone(payload["error"])
        self.assertIn("没有 rollout", " ".join(payload["warnings"]))
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))

    def test_missing_sessions_dir_exits_zero_with_warning(self):
        import shutil

        shutil.rmtree(self.home / ".codex")
        completed, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(payload["warnings"])
        self.assertIsNone(payload["error"])

    def test_log_without_rate_limits_exits_zero_with_warning(self):
        self._rollout(
            "2026/11/10/rollout-plain.jsonl",
            [
                support.token_count_line(0, 0, 0, 0, with_rate_limits=False),
                json.dumps({"timestamp": "2026-11-11T02:00:00.000Z", "type": "response_item",
                            "payload": {"type": "message"}}),
            ],
            mtime=1794200000,
        )
        completed, payload = self._run()
        self.assertEqual(payload["windows"], [])
        self.assertTrue(payload["warnings"])
        self.assertIn("rate_limits", " ".join(payload["warnings"]))

    def test_corrupt_lines_do_not_crash(self):
        self._rollout(
            "2026/11/10/rollout-broken.jsonl",
            [
                '{"broken json...',
                "not json at all",
                '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"prim',
            ],
            mtime=1794200000,
        )
        completed, payload = self._run()
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["windows"], [])
        self.assertTrue(payload["warnings"])
        self.assertIn("无法解析", " ".join(payload["warnings"]))

    def test_corrupt_lines_after_valid_frame_are_skipped(self):
        self._rollout(
            "2026/11/10/rollout-mixed.jsonl",
            [
                support.token_count_line(12.5, 6.0, 1794374936, 1794488131),
                "{oops",
            ],
            mtime=1794200000,
        )
        completed, payload = self._run()
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["windows"][0]["used_percent"], 12.5)

    def test_used_percent_missing_is_null_not_zero(self):
        line = json.dumps(
            {
                "timestamp": "2026-11-11T02:00:00.000Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "rate_limits": {
                        "primary": {"window_minutes": 300, "resets_at": 1794374936},
                        "secondary": {"window_minutes": 10080, "resets_at": 1794488131},
                        "plan_type": "plus",
                    },
                },
            }
        )
        self._rollout("2026/11/10/rollout-no-percent.jsonl", [line], mtime=1794200000)
        _, payload = self._run()
        self.assertIsNone(payload["windows"][0]["used_percent"])
        self.assertIsNone(payload["windows"][1]["used_percent"])

    def test_large_log_scans_tail_fast(self):
        # 约 8MB 填充，真正有效的帧在最后一行 —— 探针应从文件尾部找到，不读全量。
        filler = json.dumps({"type": "response_item", "payload": {"type": "message",
                                                                  "text": "x" * 400}})
        lines = [filler] * 18000
        lines.append(support.token_count_line(67.0, 5.5, 1794374936, 1794488131))
        self._rollout("2026/11/10/rollout-big.jsonl", lines, mtime=1794200000)
        self.assertGreater((self.sessions / "2026/11/10/rollout-big.jsonl").stat().st_size, 7 * 1024 * 1024)

        started = time.time()
        completed, payload = self._run()
        elapsed = time.time() - started
        self.assertEqual(payload["windows"][0]["used_percent"], 67.0)
        self.assertLess(elapsed, 1.5, "大日志下探针太慢：%.2fs" % elapsed)

    def test_json_flag_accepted(self):
        self._rollout(
            "2026/11/10/rollout.jsonl",
            [support.token_count_line(3.0, 1.0, 1794374936, 1794488131)],
            mtime=1794200000,
        )
        completed = support.run_probe("codex", self.home, args=["--json"])
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(support.parse_stdout(completed)["provider"], "codex")

    def test_unknown_argument_returns_json_error(self):
        completed = support.run_probe("codex", self.home, args=["--verbose"])
        self.assertNotEqual(completed.returncode, 0)
        payload = support.parse_stdout(completed)
        self.assertIsNotNone(payload["error"])
        self.assertEqual(payload["windows"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
