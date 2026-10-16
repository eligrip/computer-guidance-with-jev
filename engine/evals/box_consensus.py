#!/usr/bin/env python3
"""Opt-in synthetic evaluation through the production Rust NDJSON engine.

Requires Pillow. Build with `cargo build --manifest-path engine/Cargo.toml`.
Then run `python3 engine/evals/box_consensus.py --live`. No screen capture,
user notes, or microphone input is used. Prints synthetic metrics only.
"""

import argparse
import base64
import io
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]


def font(size):
    for path in ["/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def fixtures():
    image = Image.new("RGB", (1000, 650), "#eef1f5")
    draw = ImageDraw.Draw(image)
    draw.text((50, 45), "Community Center", fill="#172033", font=font(32))
    draw.text((50, 110), "Choose a section", fill="#4b5563", font=font(23))
    target = (520, 230, 920, 325)
    for bounds, label in [((80, 230, 480, 325), "Manage branding"),
                          (target, "Volunteer roles"),
                          ((80, 380, 480, 475), "Upcoming events")]:
        draw.rounded_rectangle(bounds, radius=12, fill="#2563eb")
        draw.text(((bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2),
                  label, anchor="mm", fill="white", font=font(26))
    yield "wide_button", image, target, "I want to see the volunteer roles"

    image = Image.new("RGB", (1200, 750), "#f9fafb")
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 1200, 100), fill="#e5e7eb")
    draw.text((28, 25), "Photo Library", fill="#1f2937", font=font(28))
    labels = ["Edit", "Rotate", "Favorite", "Download", "Share"]
    target = None
    for index, label in enumerate(labels):
        bounds = (590 + index * 110, 30, 690 + index * 110, 66)
        draw.rounded_rectangle(bounds, radius=5, fill="#ffffff", outline="#9ca3af")
        draw.text(((bounds[0] + bounds[2]) / 2, 48), label, anchor="mm",
                  fill="#111827", font=font(15))
        if label == "Download":
            target = bounds
    draw.rounded_rectangle((190, 180, 1010, 650), radius=10, fill="#b6d7e8")
    draw.ellipse((320, 260, 470, 410), fill="#f4c542")
    draw.polygon([(190, 650), (600, 300), (1010, 650)], fill="#5b956a")
    yield "small_toolbar", image, target, "I want to download this photo"

    image = Image.new("RGB", (1200, 750), "#dce6ec")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((75, 70, 1125, 610), radius=15, fill="#f8fafc", outline="#a1a1aa")
    draw.text((110, 105), "Reading List", fill="#334155", font=font(28))
    for row in range(6):
        draw.rounded_rectangle((115, 170 + row * 60, 1080, 210 + row * 60), radius=5, fill="#e5e7eb")
    draw.rounded_rectangle((360, 640, 840, 730), radius=22, fill="#c0cad3", outline="#94a3b8")
    target = (580, 653, 636, 709)
    for bounds, label, color in [((390, 653, 446, 709), "Files", "#4ea9e8"),
                                 ((485, 653, 541, 709), "Web", "#15a1ba"),
                                 (target, "Mail", "#3b82f6"),
                                 ((675, 653, 731, 709), "Notes", "#f4c542"),
                                 ((770, 653, 826, 709), "Chat", "#2ca66f")]:
        draw.rounded_rectangle(bounds, radius=10, fill=color)
        if label == "Mail":
            draw.rectangle((589, 666, 627, 695), fill="white")
            draw.line([(589, 666), (608, 681), (627, 666)], fill="#3b82f6", width=3)
        else:
            draw.text(((bounds[0] + bounds[2]) / 2, 681), label[0], anchor="mm", fill="white", font=font(30))
        draw.text(((bounds[0] + bounds[2]) / 2, 719), label, anchor="mm", fill="#334155", font=font(12))
    yield "dock_icon", image, target, "I want to open Mail to check my email"


def normalized(bounds, image):
    left, top, right, bottom = bounds
    return {"top": top / image.height, "bottom": bottom / image.height,
            "left": left / image.width, "right": right / image.width}


def iou(a, b):
    if a is None or b is None:
        return 0.0
    intersection = max(0, min(a["right"], b["right"]) - max(a["left"], b["left"])) * max(
        0, min(a["bottom"], b["bottom"]) - max(a["top"], b["top"]))
    union = (a["right"] - a["left"]) * (a["bottom"] - a["top"]) + (
        b["right"] - b["left"]) * (b["bottom"] - b["top"]) - intersection
    return intersection / union if union > 0 else 0.0


def center_hit(box, target):
    return box is not None and target["left"] <= (box["left"] + box["right"]) / 2 <= target["right"] and target["top"] <= (box["top"] + box["bottom"]) / 2 <= target["bottom"]


def load_key():
    value = os.environ.get("TYPESAFE_API_KEY")
    if not value:
        path = ROOT / ".env.local"
        if path.exists():
            for line in path.read_text().splitlines():
                key, separator, candidate = line.partition("=")
                if separator and key.strip() in ("TYPESAFE_API_KEY", "export TYPESAFE_API_KEY"):
                    value = candidate.strip().strip("\"'")
                    break
    if not value:
        raise SystemExit("No TypeSafe key configured. No calls made.")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Authorize synthetic TypeSafe calls")
    parser.add_argument("--rounds", type=int, default=3, choices=range(1, 11))
    parser.add_argument("--fixture", choices=("wide_button", "small_toolbar", "dock_icon"))
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live to send the generated fixtures to TypeSafe.")
    key = load_key()
    engine = ROOT / "engine/target/debug/jev-assist-engine"
    process = subprocess.Popen([str(engine)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
    sequence = 0

    def request(image, speech, count, label):
        nonlocal sequence
        sequence += 1
        encoded = io.BytesIO()
        image.save(encoded, format="JPEG", quality=92)
        message = {"id": str(sequence), "op": "guidance", "api_key": key,
                   "model": "jev-1.14.0", "minimum_presence": 0.65, "minimum_confidence": 0.25,
                   "input": {"transcript": speech, "goal": speech, "notes": "",
                             "browser_context": None, "accessibility_context": None,
                             "image_jpeg_base64": base64.b64encode(encoded.getvalue()).decode(),
                             "sample_count": count}}
        started = time.monotonic()
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        if not select.select([process.stdout], [], [], 45)[0]:
            raise RuntimeError("Synthetic engine response timed out")
        response = json.loads(process.stdout.readline())
        duration = 1000 * (time.monotonic() - started)
        if not response.get("ok"):
            # No server error bodies or request content are printed.
            error = response.get("error", {})
            print(json.dumps({"failed_request": label, "sample_count": count,
                              "latency_ms": round(duration, 1), "error": error}), flush=True)
            raise RuntimeError(f"Synthetic call failed: {error.get('message', 'Unknown engine error')}; status={error.get('status')}, retry_after={error.get('retry_after')}")
        return response["result"], duration

    try:
        cases = [case for case in fixtures() if args.fixture is None or case[0] == args.fixture]
        _, warmup_ms = request(cases[0][1], cases[0][3], 1, "warmup")
        print(json.dumps({"warmup_ms_excluded": round(warmup_ms, 1),
                          "rounds": args.rounds, "planned_provider_calls": 1 + len(cases) * args.rounds * 4}), flush=True)
        for name, image, bounds, speech in cases:
            target = normalized(bounds, image)
            standalone_ms, batch_ms, standalone_ious, sample_ious, fused_ious = [], [], [], [], []
            sample_centers = fused_centers = 0
            spreads, pairwise, unique_boxes, selected_sizes = [], [], [], []
            for round_index in range(args.rounds):
                # Alternate order so connection warming/order is not always in one mode's favor.
                results = {}
                for count in ([1, 3] if round_index % 2 == 0 else [3, 1]):
                    results[count] = request(image, speech, count, f"{name}:round_{round_index + 1}")
                baseline, single_ms = results[1]
                fused, group_ms = results[3]
                samples = fused["ensemble"]["samples"]
                boxes = [sample["box"] for sample in samples if sample["box"]]
                standalone_ms.append(single_ms)
                batch_ms.append(group_ms)
                standalone_ious.append(iou(baseline["box"], target))
                sample_ious.append([iou(sample["box"], target) for sample in samples])
                fused_ious.append(iou(fused["box"], target))
                sample_centers += sum(center_hit(sample["box"], target) for sample in samples)
                fused_centers += center_hit(fused["box"], target)
                spreads.append(max((max(box[edge] for box in boxes) - min(box[edge] for box in boxes)) *
                                   (image.height if edge in ("top", "bottom") else image.width)
                                   for edge in target) if boxes else 0)
                pairwise.extend(iou(boxes[i], boxes[j]) for i in range(len(boxes)) for j in range(i + 1, len(boxes)))
                unique_boxes.append(len({json.dumps(box, sort_keys=True) for box in boxes}))
                selected_sizes.append(len(fused["ensemble"]["selected_indices"]))
                print(json.dumps({"completed_round": f"{name}:{round_index + 1}",
                                  "standalone_ms": round(single_ms, 1), "batch_ms": round(group_ms, 1),
                                  "standalone_iou": round(standalone_ious[-1], 4),
                                  "sample_iou": [round(value, 4) for value in sample_ious[-1]],
                                  "fused_iou": round(fused_ious[-1], 4),
                                  "method": fused["ensemble"]["method"],
                                  "selected_indices": fused["ensemble"]["selected_indices"]}), flush=True)
            report = {"fixture": name, "size": list(image.size),
                      "standalone_median_ms": round(statistics.median(standalone_ms), 1),
                      "batch_median_ms": round(statistics.median(batch_ms), 1),
                      "standalone_iou_each": [round(v, 4) for v in standalone_ious],
                      "sample_iou_each": [[round(v, 4) for v in row] for row in sample_ious],
                      "sample_zero_mean_iou": round(statistics.mean(row[0] for row in sample_ious), 4),
                      "fused_iou_each": [round(v, 4) for v in fused_ious],
                      "fused_mean_iou": round(statistics.mean(fused_ious), 4),
                      "min_pairwise_iou": round(min(pairwise), 4) if pairwise else None,
                      "max_edge_spread_px": round(max(spreads), 3),
                      "unique_boxes_per_batch": unique_boxes, "selected_counts": selected_sizes,
                      "sample_center_hits": f"{sample_centers}/{3 * args.rounds}",
                      "fused_center_hits": f"{fused_centers}/{args.rounds}"}
            print(json.dumps(report), flush=True)
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
