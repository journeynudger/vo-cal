#!/usr/bin/env python3
"""Generate the Vo-Cal App Store / TestFlight app icon (1024x1024).

Why this is committed (not just the PNG): the icon is a derived artifact. Keeping
the generator next to the asset makes it reproducible and reviewable — change a
token here, re-run, and the PNG regenerates deterministically. Run from anywhere:

    python3 apps/ios/Resources/Assets.xcassets/AppIcon.appiconset/generate_icon.py

Design (frozen tokens — see docs/DESIGN.md, decision #6, black/gold palette):
  - Background: subtle vertical gradient #1A1A1A (top) -> #0E0E0E (bottom).
  - Glyph: a single gold (#C4A35A vcGold) microphone — capsule body, U-shaped
    stand/yoke, vertical post, and base bar — centered.
  - Full-bleed square, fully opaque, NO transparency, NO rounded corners
    (iOS applies the superellipse mask itself; baking corners in is a rejection
    risk and looks wrong under the mask).

Requires Pillow (PIL). Renders at 4x then downsamples for clean anti-aliased edges.
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw

# --- Frozen design tokens ----------------------------------------------------
SIZE = 1024                      # App Store / marketing icon size (single-size catalog entry)
SS = 4                           # supersampling factor for anti-aliasing
BG_TOP = (0x1A, 0x1A, 0x1A)      # #1A1A1A
BG_BOTTOM = (0x0E, 0x0E, 0x0E)   # #0E0E0E
GOLD = (0xC4, 0xA3, 0x5A)        # #C4A35A — vcGold

OUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon-1024.png")


def vertical_gradient(width: int, height: int, top: tuple[int, int, int],
                      bottom: tuple[int, int, int]) -> Image.Image:
    """Opaque top->bottom linear gradient. One row per scanline; no alpha."""
    base = Image.new("RGB", (width, height), top)
    draw = ImageDraw.Draw(base)
    for y in range(height):
        t = y / max(height - 1, 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        draw.line([(0, y), (width, y)], fill=(r, g, b))
    return base


def draw_mic(draw: ImageDraw.ImageDraw, cx: float, cy: float, scale: float,
             color: tuple[int, int, int]) -> None:
    """Draw a centered microphone glyph.

    Geometry is expressed relative to `scale` (the full-res canvas dimension) so
    the proportions hold at any supersampling factor. Coordinates are in the
    supersampled space; the caller downsamples afterward.
    """
    s = scale

    # Capsule (mic head/body): a vertically-oriented rounded rectangle.
    body_w = 0.255 * s
    body_h = 0.420 * s
    body_top = cy - 0.300 * s
    body_left = cx - body_w / 2
    body_right = cx + body_w / 2
    body_bottom = body_top + body_h
    draw.rounded_rectangle(
        [body_left, body_top, body_right, body_bottom],
        radius=body_w / 2,
        fill=color,
    )

    # Yoke / stand: a U-shaped arc cradling the lower half of the capsule.
    # Drawn as a thick arc (open at the top) using an annulus via two arcs.
    yoke_stroke = 0.060 * s
    yoke_r = body_w / 2 + 0.085 * s          # radius to the centerline of the stroke
    yoke_cx, yoke_cy = cx, body_top + body_h * 0.50
    outer = yoke_r + yoke_stroke / 2
    inner = yoke_r - yoke_stroke / 2
    # PIL arc angles: 0deg = 3 o'clock, growing clockwise (y-down). A U open at the
    # top spans from ~20deg down through the bottom to ~160deg.
    start_a, end_a = 20, 160
    draw.arc(
        [yoke_cx - outer, yoke_cy - outer, yoke_cx + outer, yoke_cy + outer],
        start=start_a, end=end_a, fill=color, width=int(round(yoke_stroke)),
    )

    # Vertical post: from the bottom of the yoke arc down toward the base.
    post_w = 0.058 * s
    post_top = yoke_cy + yoke_r - yoke_stroke / 2
    post_bottom = cy + 0.320 * s
    draw.rounded_rectangle(
        [cx - post_w / 2, post_top, cx + post_w / 2, post_bottom],
        radius=post_w / 2,
        fill=color,
    )

    # Base bar: a horizontal rounded capsule the post stands on.
    base_w = 0.300 * s
    base_h = 0.060 * s
    base_cy = post_bottom
    draw.rounded_rectangle(
        [cx - base_w / 2, base_cy - base_h / 2, cx + base_w / 2, base_cy + base_h / 2],
        radius=base_h / 2,
        fill=color,
    )


def main() -> None:
    canvas = SIZE * SS
    img = vertical_gradient(canvas, canvas, BG_TOP, BG_BOTTOM)
    draw = ImageDraw.Draw(img)

    # Center the glyph; nudge up slightly so the optical center (the heavy capsule
    # head) sits at the icon's center rather than the geometric midpoint.
    cx = canvas / 2
    cy = canvas / 2 - 0.010 * canvas
    draw_mic(draw, cx, cy, canvas, GOLD)

    # Downsample to final size for crisp anti-aliased edges.
    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    # Flatten to RGB (no alpha channel at all — App Store rejects icons with alpha).
    img = img.convert("RGB")
    img.save(OUT_PATH, "PNG")
    print(f"wrote {OUT_PATH} ({SIZE}x{SIZE}, RGB, no alpha)")


if __name__ == "__main__":
    main()
