#!/usr/bin/env python3
"""Opt-in synthetic current-utterance evaluation through the production engine.

Run with --check for offline fixture validation, or --live after building Rust.
Only invented text and the existing generated current-command.jpg are used.
Credentials enter the engine through stdin; the first service error stops calls.
"""

import argparse
import asyncio
import base64
import json
from pathlib import Path
import time

from box_consensus import load_key
from sustained_guidance import EnginePipe


ROOT = Path(__file__).resolve().parents[2]


def goal_case(name, history, latest, previous, expected):
    return {"name": name, "history": history, "utterance": latest,
            "previous": previous, "expected": expected}


GOAL_CASES = [
    goal_case("unpunctuated_new_task", "If the banner is clipped open branding",
              "take me to volunteer roles", "If the banner is clipped open branding",
              "take me to volunteer roles"),
    goal_case("pronoun_substep", "Open the shared album", "download it",
              "Open the shared album", "download it"),
    goal_case("referenced_alternative", "Open the first attachment", "the other attachment please",
              "Open the first attachment", "the other attachment please"),
    goal_case("recognition_correction", "Open the red folder", "no the blue folder",
              "Open the red folder", "no the blue folder"),
    goal_case("generic_followup_keeps_intent", "Download the report", "where do I click",
              "Download the report", "Download the report"),
    goal_case("chatter_keeps_intent", "Download the report", "the weather sounds pleasant",
              "Download the report", "Download the report"),
    goal_case("chatter_without_intent", "", "the weather sounds pleasant", None, None),
    goal_case("explicit_cancellation", "Download the report", "cancel that task",
              "Download the report", None),
    goal_case("completion", "Download the report", "that is finished thanks",
              "Download the report", None),
    goal_case("explicit_topic_return", "Open the report then open the calendar",
              "go back to the report", "open the calendar", "go back to the report"),
    goal_case("repeated_request_new_occurrence", "Open the report then open the calendar",
              "Open the report", "open the calendar", "Open the report"),
    goal_case("repeat_after_cancellation", "Save the report cancel that task",
              "Save the report", None, "Save the report"),
    goal_case("interpretable_partial", "Open the shared album", "I would like to download",
              "Open the shared album", "I would like to download"),
    goal_case("unicode_exact_source", "Find the folder", "open Zoë’s 照片",
              "Find the folder", "open Zoë’s 照片"),
]

BOX_CASES = [
    {"name": "box_new_substep", "latest": "download it", "x": .5},
    {"name": "box_new_navigation", "latest": "go back", "x": .8},
    {"name": "box_cancelled", "latest": "cancel that task", "x": None},
]


def transcript_for(case):
    # Deliberately no inserted punctuation: audio-boundary focus must work alone.
    return " ".join(part for part in [case["history"], case["utterance"]] if part)


def check_fixtures():
    names = set()
    for case in GOAL_CASES:
        assert case["name"] not in names
        names.add(case["name"])
        transcript = transcript_for(case)
        assert transcript.endswith(case["utterance"])
        assert case["expected"] is None or case["expected"] in transcript
        assert case["previous"] is None or case["previous"] in transcript
    assert len(GOAL_CASES) + len(BOX_CASES) == 17


async def run(executable, selected_names=None):
    image_path = ROOT / ".build/evals/current-command.jpg"
    if not image_path.is_file():
        raise SystemExit("Generate the synthetic fixture with engine/evals/make_command_fixture.py first.")
    encoded = base64.b64encode(image_path.read_bytes()).decode()
    key = load_key()
    engine = await EnginePipe().start(executable)
    observations = []
    provider_error = False
    planned = sum(selected_names is None or case["name"] in selected_names
                  for case in GOAL_CASES + BOX_CASES)
    try:
        for operation, cases in [("goal", GOAL_CASES), ("guidance", BOX_CASES)]:
            for case in cases:
                if selected_names is not None and case["name"] not in selected_names:
                    continue
                if operation == "goal":
                    context = {"transcript": transcript_for(case), "current_utterance": case["utterance"],
                               "previous_goal": case["previous"]}
                else:
                    context = {"transcript": "Open the shared album " + case["latest"],
                               "current_utterance": case["latest"], "goal": "Open the shared album",
                               "notes": "", "browser_context": None, "accessibility_context": None,
                               "image_jpeg_base64": encoded, "sample_count": 1}
                payload = {"op": operation, "api_key": key, "model": "jev-1.14.0",
                           "minimum_presence": .65, "minimum_confidence": .25, "input": context}
                start = time.monotonic()
                try:
                    response = await engine.request(payload)
                except Exception as error:
                    # Exceptions must never stringify a request or credential.
                    response = {"ok": False, "error": {"message": type(error).__name__}}
                row = {"case": case["name"], "operation": operation,
                       "latency_ms": round((time.monotonic() - start) * 1000, 1), "ok": response["ok"]}
                if not response["ok"]:
                    row["error"] = response["error"]  # Engine emits fixed safe messages.
                    provider_error = True
                elif operation == "goal":
                    selected = response["result"]["goal"]
                    row.update(passed=selected == case["expected"], selected=selected,
                               exact_source=selected is None or selected in context["transcript"])
                else:
                    box = response["result"]["box"]
                    passed = box is None if case["x"] is None else box is not None and (
                        abs((box["left"] + box["right"]) / 2 - case["x"]) < .12 and
                        .45 < (box["top"] + box["bottom"]) / 2 < .75)
                    row.update(passed=passed, box=box, presence=response["result"]["presence"], activity=response["result"].get("activity"))
                observations.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
                if provider_error:
                    break
            if provider_error:
                break
    finally:
        await engine.close()
    failures = [row["case"] for row in observations if not row.get("passed", False)]
    print(json.dumps({"completed": len(observations), "planned": planned,
                      "provider_error": provider_error, "failed_cases": failures}), flush=True)
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--engine", type=Path, default=ROOT / "engine/target/release/jev-assist-engine")
    parser.add_argument("--cases", help="Comma-separated synthetic case names; omit to run all 17")
    args = parser.parse_args()
    check_fixtures()
    if args.check:
        print("17 synthetic utterance fixtures validated; no provider calls.")
        return 0
    if not args.engine.is_file():
        raise SystemExit("Build the Rust engine before running the live evaluation.")
    selected = set(args.cases.split(",")) if args.cases else None
    if selected and not selected <= {case["name"] for case in GOAL_CASES + BOX_CASES}:
        parser.error("Unknown synthetic case name")
    return asyncio.run(run(args.engine, selected))


if __name__ == "__main__":
    raise SystemExit(main())
