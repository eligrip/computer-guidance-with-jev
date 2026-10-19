#!/usr/bin/env python3
"""Synthetic task continuity and screen-by-screen progress, never real cookies.

--baseline uses the legacy goal operation; --live uses paired intent selection.
Only generated images and invented speech enter the existing private engine pipe.
"""
import argparse
import asyncio
import base64
import io
import json
from pathlib import Path
import time

from box_consensus import font, load_key
from sustained_guidance import EnginePipe

ROOT = Path(__file__).resolve().parents[2]
TASK = "I want to clear the cookies in this browser."
CASES = [
    ("concrete_then_generic", "", TASK + " Where do I click?", None, None, TASK, TASK),
    ("generic_followup", TASK, "What next?", TASK, TASK, TASK, TASK),
    ("within_task_step", TASK, "Select the cookies checkbox", TASK, TASK,
     "Select the cookies checkbox", TASK),
    ("generic_after_step", TASK + " Select the cookies checkbox", "What next?",
     "Select the cookies checkbox", TASK, "Select the cookies checkbox", TASK),
    ("new_task", TASK, "I want to join my video meeting", TASK, TASK,
     "I want to join my video meeting", "I want to join my video meeting"),
    ("cancel", TASK, "Cancel that task", TASK, TASK, None, None),
    ("finished", TASK, "That is finished thanks", TASK, TASK, None, None),
    ("repeat_after_cancel", TASK + " Cancel that task", TASK, None, None, TASK, TASK),
]


def screens():
    from PIL import Image, ImageDraw
    for stage in range(5):
        image = Image.new("RGB", (1000, 700), "#f4f6f9")
        draw = ImageDraw.Draw(image)
        draw.text((35, 25), "Example Browser", font=font(26), fill="#172033")
        draw.rectangle((20, 70, 980, 115), fill="#e1e5eb")
        draw.text((45, 78), "example.test", font=font(22), fill="#334155")
        target = None

        def button(bounds, label):
            draw.rounded_rectangle(bounds, radius=7, fill="#2563eb")
            draw.text(((bounds[0]+bounds[2])/2, (bounds[1]+bounds[3])/2), label,
                      anchor="mm", font=font(21), fill="white")

        if stage == 0:
            draw.text((70, 170), "Browser settings", font=font(30), fill="#172033")
            button((70, 240, 390, 305), "Privacy and security")
            button((70, 350, 390, 415), "Appearance")
            target = (70, 240, 390, 305)
        elif stage == 1:
            draw.text((70, 170), "Privacy and security", font=font(30), fill="#172033")
            button((70, 250, 410, 320), "Delete browsing data")
            button((70, 370, 410, 440), "Site permissions")
            target = (70, 250, 410, 320)
        elif stage in (2, 3):
            draw.rounded_rectangle((150, 155, 850, 615), radius=16, fill="white", outline="#64748b")
            draw.text((190, 185), "Delete browsing data", font=font(30), fill="#172033")
            draw.text((190, 245), "Time range: All time", font=font(23), fill="#172033")
            for y, label, checked in [(325, "Browsing history", False),
                                      (395, "Cookies and other site data", stage == 3),
                                      (465, "Cached images and files", False)]:
                draw.rectangle((195, y, 223, y+28), outline="#334155", width=2,
                               fill="#2563eb" if checked else "white")
                if checked:
                    draw.line([(200, y+14), (207, y+21), (219, y+7)], fill="white", width=3)
                draw.text((245, y), label, font=font(23), fill="#172033")
            button((600, 530, 805, 585), "Delete data")
            target = (195, 395, 223, 423) if stage == 2 else (600, 530, 805, 585)
        else:
            draw.text((170, 260), "Cookies and site data deleted", font=font(34), fill="#172033")
            draw.text((170, 330), "Your selected browser data has been cleared.", font=font(23), fill="#334155")
        data = io.BytesIO()
        image.save(data, format="JPEG", quality=92)
        yield f"cookie_stage_{stage}", base64.b64encode(data.getvalue()).decode(), target


async def run(args):
    engine = await EnginePipe().start(args.engine)
    key = load_key()
    rows = []
    async def request(op, context):
        start = time.monotonic()
        reply = await engine.request({"op": op, "api_key": key, "model": "jev-1.14.0",
            "minimum_presence": .65, "minimum_confidence": .25, "input": context})
        if not reply["ok"]:
            raise RuntimeError(reply.get("error", {}).get("message", "Engine failed"))
        return reply["result"], round((time.monotonic()-start)*1000, 1)

    def record(row):
        rows.append(row)
        print(json.dumps(row), flush=True)

    try:
        for name, history, latest, goal, task, expected_goal, expected_task in CASES:
            context = {"transcript": " ".join(filter(None, [history, latest])),
                       "current_utterance": latest, "previous_goal": goal, "previous_task": task}
            result, latency = await request("goal" if args.baseline else "intent", context)
            record({"case": name, "latency_ms": latency, "result": result,
                    "passed": result["goal"] == expected_goal and
                    (args.baseline or result["task"] == expected_task)})
        # Carry a task through a concrete substep and then generic help. No
        # restatement between screenshots, and no expected workflow in prompts.
        transcript = TASK + " Select the cookies checkbox. What next?"
        result, _ = await request("goal" if args.baseline else "intent", {
            "transcript": transcript, "current_utterance": "What next?",
            "previous_goal": "Select the cookies checkbox.", "previous_task": TASK})
        for name, encoded, target in screens():
            result_box, latency = await request("guidance", {
                "transcript": transcript, "current_utterance": "What next?", "goal": result["goal"],
                "task_anchor": result.get("task"), "notes": "", "browser_context": None,
                "accessibility_context": None, "image_jpeg_base64": encoded})
            box = result_box["box"]
            if target is None:
                passed = box is None
            else:
                passed = box is not None and target[0] <= (box["left"]+box["right"])*500 <= target[2] and (
                    target[1] <= (box["top"]+box["bottom"])*350 <= target[3])
            record({"case": name, "latency_ms": latency, "passed": passed,
                    "box": box, "presence": result_box["presence"], "activity": result_box.get("activity")})
    finally:
        await engine.close()
    report = {"baseline": args.baseline, "passed": sum(row["passed"] for row in rows),
              "total": len(rows), "rows": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps({k:v for k,v in report.items() if k != "rows"}))
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--engine", type=Path, default=ROOT/"engine/target/release/jev-assist-engine")
    parser.add_argument("--output", type=Path, default=ROOT/".build/evals/multistep.json")
    raise SystemExit(asyncio.run(run(parser.parse_args())))
