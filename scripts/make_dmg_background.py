#!/usr/bin/env python3
"""
make_dmg_background.py — regenerates the DMG installer background image.

Draws a simple light background with an instructional arrow between the
app-icon drop spot and the Applications-folder drop spot. Icon artwork
itself is NOT baked in here (Finder draws the real .app / Applications
icons on top at the positions set by build-release.sh's AppleScript step);
this image only supplies the guide arrow + label + subtle drop-zone circles
so the two icon positions line up with what's drawn here.

Usage:
    python3 scripts/make_dmg_background.py <output.png> [--2x]

Re-run this whenever WINDOW_W/WINDOW_H or the icon positions in
build-release.sh change, so the arrow stays aligned with the icons.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

# Must match the Finder window size + icon positions used in build-release.sh.
WINDOW_W, WINDOW_H = 660, 420
APP_ICON_X, ICON_Y = 165, 190
FOLDER_ICON_X = 495
ICON_SIZE = 128


def build(scale=1):
    w, h = WINDOW_W * scale, WINDOW_H * scale
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)

    # Soft vertical gradient background (light warm gray -> white).
    top = (238, 240, 244)
    bottom = (255, 255, 255)
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        d.line([(0, y), (w, y)], fill=(r, g, b))

    # Title bar hairline (Finder draws its own toolbar above this image, so
    # just add a touch of top padding via a subtle divider is unnecessary;
    # skip to keep it clean).

    # Drop-zone guide circles under where the real icons will sit.
    def guide_circle(cx):
        r = int(ICON_SIZE * 0.62 * scale)
        cx, cy = cx * scale, ICON_Y * scale
        d.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            outline=(210, 213, 219),
            width=max(1, 2 * scale),
        )

    guide_circle(APP_ICON_X)
    guide_circle(FOLDER_ICON_X)

    # Arrow between the two icons.
    arrow_y = ICON_Y * scale
    x0 = (APP_ICON_X + ICON_SIZE * 0.62) * scale
    x1 = (FOLDER_ICON_X - ICON_SIZE * 0.62) * scale
    shaft_w = max(2, int(4 * scale))
    d.line([(x0, arrow_y), (x1 - 14 * scale, arrow_y)], fill=(150, 155, 165), width=shaft_w)
    head = [
        (x1, arrow_y),
        (x1 - 16 * scale, arrow_y - 10 * scale),
        (x1 - 16 * scale, arrow_y + 10 * scale),
    ]
    d.polygon(head, fill=(150, 155, 165))

    # Instructional label.
    label = "Kéo PetMacOS vào Applications để cài đặt"
    font = None
    for candidate in (
        "/System/Library/Fonts/SFNSText.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        try:
            font = ImageFont.truetype(candidate, 15 * scale)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()

    bbox = d.textbbox((0, 0), label, font=font)
    text_w = bbox[2] - bbox[0]
    text_x = (w - text_w) / 2
    text_y = (ICON_Y + ICON_SIZE * 0.62 + 26) * scale
    d.text((text_x, text_y), label, fill=(90, 94, 102), font=font)

    return img


def main():
    if len(sys.argv) < 2:
        print("usage: make_dmg_background.py <output.png> [--2x]", file=sys.stderr)
        sys.exit(1)
    out_path = sys.argv[1]
    scale = 2 if "--2x" in sys.argv[2:] else 1
    img = build(scale=scale)
    img.save(out_path)
    print(f"Wrote {out_path} ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()
