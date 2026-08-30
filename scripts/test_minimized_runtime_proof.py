#!/usr/bin/env python3

import datetime
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("verify_minimized_runtime_proof.py")
SPEC = importlib.util.spec_from_file_location("verify_minimized_runtime_proof", MODULE_PATH)
proof = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(proof)


class MinimizedRuntimeProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.built_at = datetime.datetime(2026, 8, 30, 9, 0, tzinfo=datetime.timezone.utc)

    @staticmethod
    def line(timestamp: str, **overrides) -> bytes:
        import json

        payload = {
            "event": "minimized_window_snapshot",
            "timestamp": timestamp,
            "complete": True,
            "candidate_apps": 53,
            "scanned_apps": 53,
            "count": 1,
            "scanned_windows": 7,
        }
        payload.update(overrides)
        return json.dumps(payload, sort_keys=True).encode() + b"\n"

    def test_selects_latest_complete_post_build_snapshot(self) -> None:
        earlier = self.line("2026-08-30T08:59:59Z", candidate_apps=2, scanned_apps=2)
        first = self.line("2026-08-30T09:00:01Z", candidate_apps=40, scanned_apps=40)
        latest = self.line("2026-08-30T09:00:02Z")

        payload, raw = proof.select_snapshot_line([earlier, first, latest], self.built_at)

        self.assertEqual(payload["candidate_apps"], 53)
        self.assertEqual(raw, latest.rstrip())

    def test_rejects_incomplete_or_empty_snapshot(self) -> None:
        lines = [
            self.line("2026-08-30T09:00:01Z", complete=False),
            self.line("2026-08-30T09:00:02Z", count=0),
            self.line("2026-08-30T09:00:03Z", scanned_apps=32),
        ]

        with self.assertRaises(proof.ProofError):
            proof.select_snapshot_line(lines, self.built_at)

    def test_rejects_window_count_that_cannot_cover_result(self) -> None:
        line = self.line("2026-08-30T09:00:01Z", count=2, scanned_windows=1)

        with self.assertRaises(proof.ProofError):
            proof.select_snapshot_line([line], self.built_at)

    def test_build_script_embeds_staged_source_identity(self) -> None:
        build_script = MODULE_PATH.with_name("build-app.sh").read_text(encoding="utf-8")

        self.assertIn("SwitchBladeSourceHead", build_script)
        self.assertIn("SwitchBladeSourceState", build_script)
        self.assertIn("SwitchBladeSourceTree", build_script)
        self.assertIn('source_state="working-copy"', build_script)


if __name__ == "__main__":
    unittest.main()
