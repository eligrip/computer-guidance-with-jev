#!/usr/bin/env python3
"""Synthetic engine scheduler checks; no provider calls, Pillow or credentials."""
import asyncio
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine/evals"))
from sustained_guidance import run_profile

BOX = {"left": .1, "top": .1, "right": .3, "bottom": .3}
CASE = {"name": "synthetic", "image": "unused", "target": BOX,
        "speech": "Open Mail.", "expected_goal": "Open Mail.", "old_goal": None}


def answer(payload):
    result = {"goal": "Open Mail."} if payload["op"] == "goal" else {"box": BOX}
    return {"ok": True, "result": result}


class SustainedGuidanceTests(unittest.IsolatedAsyncioTestCase):
    async def test_fills_available_slots_without_exceeding_http_budget(self):
        for targets, samples in [(6, 1), (2, 3)]:
            active = peak = 0

            async def request(payload):
                nonlocal active, peak
                cost = payload["input"].get("sample_count", 1)
                active += cost
                peak = max(peak, active)
                await asyncio.sleep(.1)
                active -= cost
                return answer(payload)

            report = await run_profile(request, "synthetic", [CASE],
                                       {"targets": targets, "samples": samples, "interval": .005,
                                        "goal_interval": .03}, .25)
            self.assertEqual(report["peak_in_flight"]["guidance"], targets)
            self.assertEqual(report["peak_in_flight"]["goal"], 2)
            self.assertEqual(peak, 8)
            self.assertEqual(active, 0)
            self.assertFalse(report["errors"])
            self.assertEqual(report["target_center_hits"], report["completed_target_operations"])

    async def test_error_stops_dispatch_but_drains_existing_work(self):
        calls = 0
        completed = 0

        async def request(payload):
            nonlocal calls, completed
            calls += 1
            if payload["op"] == "goal":
                await asyncio.sleep(.01)
                completed += 1
                return {"ok": False, "error": {"status": 429, "retry_after": 2}}
            await asyncio.sleep(.08)
            completed += 1
            return answer(payload)

        report = await run_profile(request, "synthetic", [CASE],
                                   {"targets": 6, "samples": 1, "interval": .035}, .3)
        self.assertTrue(report["stopped_early"])
        self.assertEqual(calls, 2)
        self.assertEqual(completed, calls)
        self.assertEqual(report["errors"][0]["error"]["retry_after"], 2)

    async def test_old_scene_answer_does_not_count_as_first_response(self):
        async def request(payload):
            await asyncio.sleep(.05)
            return answer(payload)

        report = await run_profile(request, "synthetic", [CASE],
                                   {"targets": 2, "samples": 1, "interval": .005}, .1, scene_seconds=.02)
        self.assertGreater(report["stale_scene_responses"], 0)
        self.assertFalse(report["first_correct_after_scene_change_ms"])

    async def test_call_limit_counts_each_consensus_sample(self):
        async def request(payload):
            await asyncio.sleep(.02)
            return answer(payload)

        report = await run_profile(request, "synthetic", [CASE],
                                   {"targets": 2, "samples": 3, "interval": .005}, .1, call_limit=7)
        self.assertEqual(report["attempted_http_calls"], 7)
        self.assertEqual(report["completed_target_operations"], 2)
        self.assertEqual(report["completed_goal_operations"], 1)

    async def test_opt_in_transport_recovery_waits_and_keeps_checking(self):
        loop = asyncio.get_running_loop()
        target_times = []

        async def request(payload):
            if payload["op"] == "guidance":
                target_times.append(loop.time())
                if len(target_times) == 1:
                    return {"ok": False, "error": {"status": None, "message":
                            "Could not connect to TypeSafe. Check the network connection."}}
            return answer(payload)

        report = await run_profile(request, "synthetic", [CASE],
                                   {"targets": 1, "samples": 1, "interval": .005}, .35,
                                   recover_transport=True)
        self.assertFalse(report["stopped_early"])
        self.assertEqual(len(report["errors"]), 1)
        self.assertGreater(report["completed_target_operations"], 1)
        self.assertGreaterEqual(target_times[1] - target_times[0], .25)


if __name__ == "__main__":
    unittest.main()
