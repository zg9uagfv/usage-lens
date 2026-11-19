#!/usr/bin/env python3
"""Claude Code 探针验收：无窗口、今日 tokens 口径（in+out 主数字 + cache 单列）、
花费按牌价估算、<synthetic> 跳过、防泄露、不写文件。

全部用临时 HOME 隔离，不碰真实用户目录，不发网络。
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import support


def load_probe():
    path = support.PROBES / "claude.py"
    spec = importlib.util.spec_from_file_location("probe_claude_under_test", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def iso_utc(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def assistant_line(input_tokens=0, output_tokens=0, cache_write=0, cache_read=0,
                   model="claude-sonnet-4-5", timestamp=None):
    """造一条 type==assistant 的会话 JSONL 行（真实形状：message.usage + message.model）。"""
    if timestamp is None:
        timestamp = iso_utc(datetime.datetime.now(datetime.timezone.utc))
    event = {
        "type": "assistant",
        "timestamp": timestamp,
        "sessionId": "test-session",
        "message": {
            "model": model,
            "usage": {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cache_creation_input_tokens": cache_write,
                "cache_read_input_tokens": cache_read,
            },
        },
    }
    return json.dumps(event, ensure_ascii=False)


def synthetic_line():
    """本地生成的合成消息行：usage 全 0，探针应跳过。"""
    event = {
        "type": "assistant",
        "timestamp": iso_utc(datetime.datetime.now(datetime.timezone.utc)),
        "message": {"model": "<synthetic>", "usage": {"input_tokens": 999, "output_tokens": 999}},
    }
    return json.dumps(event, ensure_ascii=False)


def write_session(home: Path, project_slug: str, session_id: str, lines, mtime=None) -> Path:
    directory = home / ".claude" / "projects" / project_slug
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (session_id + ".jsonl")
    with path.open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class ClaudeProbeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = support.make_home(self.tmp)
        self.projects = self.home / ".claude" / "projects"
        self.projects.mkdir(parents=True, exist_ok=True)
        self.module = load_probe()
        self.module.PROJECTS_DIR = self.projects

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, args=None):
        return support.run_probe("claude", self.home, args=args)

    # ---------- 端到端 ----------

    def test_empty_home_exits_zero_no_data(self):
        completed = self._run()
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
        payload = support.parse_stdout(completed)
        self.assertEqual(set(payload), support.HEADER_KEYS)
        self.assertEqual(payload["schema"], "usage-lens/probe@1")
        self.assertEqual(payload["provider"], "claude")
        self.assertEqual(payload["windows"], [])  # Claude 本地无窗口进度
        self.assertIsNone(payload["usage"])
        self.assertIsNone(payload["spend"])
        self.assertIsNone(payload["error"])
        self.assertFalse(payload["stale"])
        self.assertTrue(any("没有" in item or "未找到" in item for item in payload["warnings"]))
        support.assert_no_secrets(self, completed.stdout.decode("utf-8"))
        support.assert_no_secrets(self, completed.stderr.decode("utf-8"))

    def test_unknown_argument_returns_exit_2(self):
        completed = self._run(args=["--debug"])
        self.assertEqual(completed.returncode, 2)
        payload = support.parse_stdout(completed)
        self.assertIn("不支持的参数", payload["error"])

    def test_windows_always_empty_even_with_usage(self):
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1000, output_tokens=5000)],
        )
        payload = support.parse_stdout(self._run())
        self.assertEqual(payload["windows"], [])
        self.assertEqual(payload["provider"], "claude")

    def test_output_is_strict_json(self):
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1000, output_tokens=5000)],
        )
        completed = self._run()
        support.strict_loads(completed.stdout.decode("utf-8"))

    # ---------- 今日 tokens 口径 ----------

    def test_today_tokens_is_input_plus_output_only(self):
        # 主数字只算 in+out；cache read 巨大但单列到 warning，不进主数字
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1000, output_tokens=5000,
                            cache_write=200000, cache_read=50000000)],
        )
        payload = support.parse_stdout(self._run())
        usage = payload["usage"]
        self.assertIsNotNone(usage)
        self.assertEqual(usage["today_tokens"], 6000)  # 1000 + 5000，不含 cache
        self.assertEqual(usage["source"], "local")
        # cache 单列在 warning
        self.assertTrue(any("cache tokens" in item for item in payload["warnings"]))
        self.assertTrue(any("50000000" in item or "读 50000000" in item for item in payload["warnings"]))

    def test_synthetic_lines_are_skipped(self):
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=100, output_tokens=200), synthetic_line()],
        )
        payload = support.parse_stdout(self._run())
        self.assertEqual(payload["usage"]["today_tokens"], 300)  # 只算真实那条

    def test_no_today_usage_gives_null_usage(self):
        # 只有 5 天前的用量，今天没有 -> usage 应为 null
        old = iso_utc(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5))
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1000, output_tokens=1000, timestamp=old)],
        )
        payload = support.parse_stdout(self._run())
        self.assertIsNone(payload["usage"])
        # 但 5 天前在近 7 天窗口内，spend.window 应 > 0
        self.assertIsNotNone(payload["spend"])
        self.assertGreater(payload["spend"]["window"], 0)

    # ---------- 花费估算 ----------

    def test_spend_estimate_sonnet(self):
        # sonnet: in $3/M, out $15/M。1M in + 1M out = 3 + 15 = $18
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1_000_000, output_tokens=1_000_000, model="claude-sonnet-4-5")],
        )
        payload = support.parse_stdout(self._run())
        spend = payload["spend"]
        self.assertIsNotNone(spend)
        self.assertAlmostEqual(spend["today"], 18.0, places=2)
        self.assertAlmostEqual(spend["window"], 18.0, places=2)
        self.assertEqual(spend["currency"], "USD")
        self.assertEqual(spend["source"], "estimate")
        # 「估算」口径写在 coverage.note（warnings 只放告警类，如未识别模型/cache 明细）
        self.assertIn("牌价", payload["coverage"]["note"])
        self.assertIn("Anthropic", payload["coverage"]["note"])
        self.assertIn("非官方账单", payload["coverage"]["note"])

    def test_spend_estimate_cache_tokens(self):
        # sonnet: cache_write $3.75/M, cache_read $0.3/M
        # 1M in(3) + 0 out + 1M cw(3.75) + 1M cr(0.3) = 7.05
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1_000_000, output_tokens=0,
                            cache_write=1_000_000, cache_read=1_000_000, model="claude-sonnet-4-5")],
        )
        payload = support.parse_stdout(self._run())
        self.assertAlmostEqual(payload["spend"]["today"], 7.05, places=2)

    def test_spend_estimate_opus_costs_more(self):
        # opus: in $15/M。1M in = $15（比 sonnet 的 $3 贵）
        write_session(
            self.home, "proj-opus", "s1",
            [assistant_line(input_tokens=1_000_000, output_tokens=0, model="claude-opus-4-1")],
        )
        payload = support.parse_stdout(self._run())
        self.assertAlmostEqual(payload["spend"]["today"], 15.0, places=2)

    def test_spend_window_excludes_older_than_7_days(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        eight_days_ago = iso_utc(now - datetime.timedelta(days=8))
        today_iso = iso_utc(now)
        write_session(
            self.home, "proj", "s1",
            [
                assistant_line(input_tokens=1_000_000, output_tokens=0, model="claude-sonnet-4-5",
                               timestamp=eight_days_ago),
                assistant_line(input_tokens=0, output_tokens=1_000_000, model="claude-sonnet-4-5",
                               timestamp=today_iso),
            ],
        )
        payload = support.parse_stdout(self._run())
        spend = payload["spend"]
        self.assertAlmostEqual(spend["today"], 15.0, places=2)    # 今天 1M out *15
        self.assertAlmostEqual(spend["window"], 15.0, places=2)   # 近 7 天不含 8 天前
        self.assertEqual(payload["coverage"]["from"], (now - datetime.timedelta(days=8)).date().isoformat())
        self.assertEqual(payload["coverage"]["to"], datetime.date.today().isoformat())

    def test_unknown_model_falls_back_and_warns(self):
        write_session(
            self.home, "proj", "s1",
            [assistant_line(input_tokens=1_000_000, output_tokens=0, model="mystery-model-x")],
        )
        payload = support.parse_stdout(self._run())
        # 未识别家族 -> 按 sonnet 兜底：1M in *3 = $3
        self.assertAlmostEqual(payload["spend"]["today"], 3.0, places=2)
        self.assertTrue(any("未识别的模型" in item for item in payload["warnings"]))

    def test_corrupt_lines_are_skipped_with_warning(self):
        write_session(
            self.home, "proj", "s1",
            ["this is not json", assistant_line(input_tokens=100, output_tokens=100)],
        )
        payload = support.parse_stdout(self._run())
        self.assertEqual(payload["usage"]["today_tokens"], 200)
        self.assertTrue(any("无法解析" in item for item in payload["warnings"]))

    # ---------- 安全 ----------

    def test_probe_writes_no_files(self):
        before = support.fingerprint(self.home)
        write_session(self.home, "proj", "s1", [assistant_line(input_tokens=100, output_tokens=100)])
        before = support.fingerprint(self.home)  # 写完 fixture 后再取基线
        self._run()
        self.assertEqual(support.fingerprint(self.home), before)

    def test_multiple_projects_are_aggregated(self):
        write_session(self.home, "proj-a", "s1", [assistant_line(input_tokens=100, output_tokens=100)])
        write_session(self.home, "proj-b", "s2", [assistant_line(input_tokens=50, output_tokens=50)])
        payload = support.parse_stdout(self._run())
        self.assertEqual(payload["usage"]["today_tokens"], 300)  # 跨项目求和


if __name__ == "__main__":
    unittest.main(verbosity=2)
