"""Generate the fixed synthetic image used by opt-in Rust live evaluations.

Requires Pillow. Does not read any screen, image, notes, or microphone input.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

image = Image.new("RGB", (900, 400), "#f1f5f9")
draw = ImageDraw.Draw(image)
font_paths = ["/System/Library/Fonts/Supplemental/Arial.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
font_path = next((path for path in font_paths if Path(path).exists()), None)
font = ImageFont.truetype(font_path, 24) if font_path else ImageFont.load_default(size=24)
draw.text((50, 40), "Shared album", font=font, fill="#172033")
for x, label in [(180, "Open album"), (450, "Download"), (720, "Go back")]:
    draw.rounded_rectangle((x - 105, 180, x + 105, 300), radius=14, fill="#2563eb")
    draw.text((x, 240), label, anchor="mm", font=font, fill="white")
path = Path(__file__).resolve().parents[2] / ".build/evals/current-command.jpg"
path.parent.mkdir(parents=True, exist_ok=True)
image.save(path, quality=92)
print(path)
