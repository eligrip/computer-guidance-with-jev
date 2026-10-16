#!/usr/bin/env python3
"""Bounded, opt-in sustained synthetic evaluation through the Rust pipe protocol.

Measures engine throughput, accuracy and first correct answer after each synthetic
scene change. This is not a microphone/capture/overlay end-to-end measurement.
Stops dispatching on the first provider error, drains outstanding work, and exits.
"""

import argparse
import asyncio
import base64
import io
import json
import math
from pathlib import Path
import statistics
import time


ROOT = Path(__file__).resolve().parents[2]
PROFILES = {
    "old_two": {"targets": 2, "samples": 1, "interval": .1},
    "fast_single": {"targets": 6, "samples": 1, "interval": .035},
    "fast_three": {"targets": 2, "samples": 3, "interval": .035},
    "fast_talking": {"targets": 6, "samples": 1, "interval": .035, "goal_interval": .12},
    "faster_six": {"targets": 6, "samples": 1, "interval": .02, "goal_interval": .12},
    "faster_eight": {"targets": 8, "samples": 1, "interval": .02, "goal_interval": .12},
    "faster_three": {"targets": 2, "samples": 3, "interval": .02, "goal_interval": .12},
}


def percentile(values, fraction):
    return round(sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)], 1) if values else None


class EnginePipe:
    async def start(self, executable):
        self.pending = {}
        self.sequence = 0
        self.lock = asyncio.Lock()
        self.process = await asyncio.create_subprocess_exec(
            str(executable), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, limit=2 * 1024 * 1024)
        self.reader = asyncio.create_task(self.read())
        return self

    async def read(self):
        try:
            while line := await self.process.stdout.readline():
                response = json.loads(line)
                future = self.pending.pop(response["id"], None)
                if future and not future.done():
                    future.set_result(response)
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(RuntimeError("Engine pipe closed before answering"))

    async def request(self, payload):
        self.sequence += 1
        identifier = str(self.sequence)
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        try:
            async with self.lock:
                self.process.stdin.write((json.dumps(dict(payload, id=identifier)) + "\n").encode())
                await self.process.stdin.drain()
            return await asyncio.wait_for(future, timeout=40)
        finally:
            self.pending.pop(identifier, None)

    async def close(self):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), timeout=3)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()
        await self.reader


def prepare_cases():
    from box_consensus import fixtures, normalized
    cases = []
    history = []
    for name, image, bounds, speech in fixtures():
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=92)
        history.append(speech + ".")
        cases.append({"name": name, "image": base64.b64encode(output.getvalue()).decode(),
                      "target": normalized(bounds, image), "speech": " ".join(history),
                      "expected_goal": history[-1], "old_goal": history[-2] if len(history) > 1 else None})
    return cases


def payload_for(key, case, operation, samples):
    context = {"transcript": case["speech"]}
    if operation == "goal":
        context["previous_goal"] = case["old_goal"]
    else:
        context.update(goal=case["old_goal"], notes="", browser_context=None,
                       accessibility_context=None, image_jpeg_base64=case["image"], sample_count=samples)
    return {"op": operation, "api_key": key, "model": "jev-1.14.0",
            "minimum_presence": .65, "minimum_confidence": .25, "input": context}


async def run_profile(request, key, cases, profile, seconds, scene_seconds=2, call_limit=1000,
                      recover_transport=False):
    """No accumulated queue: dispatch only when both time and capacity allow."""
    from box_consensus import center_hit, iou
    start = time.monotonic()
    active = {"guidance": 0, "goal": 0}
    peak = {"guidance": 0, "goal": 0, "http": 0}
    last = {"guidance": -float("inf"), "goal": -float("inf")}
    pending = set()
    rows = []
    first_correct = {}
    attempted = 0
    stopped = False
    retry_at = 0
    failures = 0

    async def perform(operation, phase, case, issued):
        nonlocal stopped, retry_at, failures
        try:
            response = await request(payload_for(key, case, operation, profile["samples"]))
            completed = time.monotonic() - start
            row = {"op": operation, "phase": phase, "case": case["name"],
                   "issued_ms": round(issued * 1000, 1), "latency_ms": round((completed - issued) * 1000, 1),
                   "stale_scene": int(completed / scene_seconds) != phase, "ok": response["ok"]}
            if not response["ok"]:
                # Fixed engine errors contain no request body or credential.
                row["error"] = response["error"]
                if recover_transport and response["error"].get("status") is None and response["error"].get("message") == (
                        "Could not connect to TypeSafe. Check the network connection."):
                    failures += 1
                    delay = min(2, .25 * 2 ** min(failures - 1, 3))
                    retry_at = max(retry_at, completed + delay)
                    row["transport_backoff_ms"] = delay * 1000
                else:
                    stopped = True
            elif operation == "guidance":
                failures = 0
                box = response["result"]["box"]
                row.update(hit=center_hit(box, case["target"]), iou=round(iou(box, case["target"]), 4),
                           abstained=box is None)
                if row["hit"] and not row["stale_scene"]:
                    first_correct.setdefault(phase, round((completed - phase * scene_seconds) * 1000, 1))
            else:
                goal = response["result"]["goal"]
                row["hit"] = goal is not None and goal.rstrip(".") == case["expected_goal"].rstrip(".")
            rows.append(row)
        except Exception as error:
            # Never stringify arbitrary errors that could contain request data.
            stopped = True
            rows.append({"op": operation, "ok": False, "error": {"message": type(error).__name__}})
        finally:
            active[operation] -= 1

    while time.monotonic() - start < seconds and not stopped:
        now = time.monotonic() - start
        if now < retry_at:
            await asyncio.sleep(min(.01, retry_at - now))
            continue
        phase = int(now / scene_seconds)
        case = cases[phase % len(cases)]
        for operation, cap, interval, cost in (
            ("goal", 2, profile.get("goal_interval", .5), 1),
            ("guidance", profile["targets"], profile["interval"], profile["samples"]),
        ):
            if active[operation] >= cap or now - last[operation] < interval:
                continue
            if attempted + cost > call_limit:
                stopped = True
                break
            active[operation] += 1
            peak[operation] = max(peak[operation], active[operation])
            peak["http"] = max(peak["http"], active["guidance"] * profile["samples"] + active["goal"])
            attempted += cost
            last[operation] = now
            task = asyncio.create_task(perform(operation, phase, case, now))
            pending.add(task)
            task.add_done_callback(pending.discard)
        await asyncio.sleep(.001)
    dispatch_seconds = time.monotonic() - start
    if pending:
        await asyncio.gather(*pending)
    wall = time.monotonic() - start
    targets = [row for row in rows if row["op"] == "guidance" and row["ok"]]
    goals = [row for row in rows if row["op"] == "goal" and row["ok"]]
    errors = [row for row in rows if not row["ok"]]
    successful_http_calls = len(targets) * profile["samples"] + len(goals) + sum(
        row["error"].get("completed_calls") or 0 for row in errors)
    by_case = {}
    for case in cases:
        group = [row for row in targets if row["case"] == case["name"]]
        by_case[case["name"]] = {
            "completed": len(group), "hits": sum(row["hit"] for row in group),
            "abstentions": sum(row["abstained"] for row in group),
            "mean_iou": round(statistics.mean(row["iou"] for row in group), 4) if group else None,
            "latency_median_ms": percentile([row["latency_ms"] for row in group], .5),
            "latency_p95_ms": percentile([row["latency_ms"] for row in group], .95),
        }
    return {"configured_seconds": seconds, "dispatch_seconds": round(dispatch_seconds, 3),
            "wall_seconds_including_drain": round(wall, 3), "stopped_early": stopped,
            "transport_recovery_enabled": recover_transport,
            "attempted_http_calls": attempted, "completed_target_operations": len(targets),
            "successful_http_calls": successful_http_calls,
            "completed_goal_operations": len(goals), "errors": errors, "peak_in_flight": peak,
            "target_operations_per_second": round(len(targets) / wall, 2),
            "successful_http_calls_per_second": round(successful_http_calls / wall, 2),
            "target_latency_median_ms": percentile([r["latency_ms"] for r in targets], .5),
            "target_latency_p95_ms": percentile([r["latency_ms"] for r in targets], .95),
            "goal_latency_p95_ms": percentile([r["latency_ms"] for r in goals], .95),
            "target_center_hits": sum(r["hit"] for r in targets),
            "target_abstentions": sum(r["abstained"] for r in targets),
            "target_mean_iou": round(statistics.mean(r["iou"] for r in targets), 4) if targets else None,
            "goal_hits": sum(r["hit"] for r in goals),
            "stale_scene_responses": sum(r["stale_scene"] for r in targets),
            "fully_observed_phases_without_correct_answer": [phase for phase in range(int(dispatch_seconds / scene_seconds))
                                                             if phase not in first_correct],
            "first_correct_after_scene_change_ms": first_correct,
            "by_case": by_case,
            "calls": rows}


async def main(args):
    from box_consensus import load_key
    key, cases = load_key(), prepare_cases()
    pipe = await EnginePipe().start(args.engine)
    reports = []
    try:
        warmup = await pipe.request(payload_for(key, cases[0], "guidance", 1))
        if not warmup["ok"]:
            print(json.dumps({"warmup_error": warmup["error"]}), flush=True)
            return 1
        names = args.profiles.split(",")
        for name in names:
            report = await run_profile(pipe.request, key, cases, PROFILES[name], args.seconds,
                                       recover_transport=args.recover_transport)
            report["profile"] = name
            reports.append(report)
            print(json.dumps({k: v for k, v in report.items() if k != "calls"}), flush=True)
            if report["stopped_early"]:
                break  # No retry storm or next profile after a provider rejection.
    finally:
        await pipe.close()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(reports, indent=2) + "\n")
    return int(any(report["errors"] for report in reports))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--recover-transport", action="store_true",
                        help="Continue fresh checks after bounded connection-failure backoff; HTTP errors still stop")
    parser.add_argument("--seconds", type=int, default=15, choices=range(2, 61))
    parser.add_argument("--profiles", default="old_two,fast_single,fast_three")
    parser.add_argument("--engine", type=Path, default=ROOT / "engine/target/release/jev-assist-engine")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/evals/sustained-guidance.json")
    args = parser.parse_args()
    if not args.live or any(name not in PROFILES for name in args.profiles.split(",")):
        parser.error("Use --live and valid comma-separated profiles: " + ",".join(PROFILES))
    raise SystemExit(asyncio.run(main(args)))
