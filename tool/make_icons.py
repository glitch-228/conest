#!/usr/bin/env python3
"""Generates Conest's app icons from assets/branding/conest_logo.png.

    python3 tool/make_icons.py [--preview out.png]

Writes the Android launcher icons (legacy, round, adaptive with a themed
monochrome layer), the Android notification icon, the Windows .ico and the
Linux window icon. The logo is a light glyph on a flat dark background; the
glyph is separated from the background by colour distance.
"""

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/branding/conest_logo.png"
RES = ROOT / "android/app/src/main/res"
DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}

# Share of a legacy or desktop icon the glyph's longer side fills.
LEGACY_GLYPH = 0.74
# Adaptive icons are 108 dp; launchers mask them to a 66 dp circle at the
# least, so the glyph's box must stay inside it (corners included).
ADAPTIVE_GLYPH_DP = 46
# Status bar icons are 24 dp with a little padding.
STATUS_GLYPH_DP = 22


def load():
    image = Image.open(SOURCE).convert("RGB")
    corners = [
        image.getpixel((x, y))
        for x in (4, image.width - 5)
        for y in (4, image.height - 5)
    ]
    background = tuple(sorted(c[i] for c in corners)[1] for i in range(3))
    # Alpha from the distance to the background, with soft edges.
    pixels = image.load()
    glyph = Image.new("RGBA", image.size)
    out = glyph.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b = pixels[x, y]
            distance = math.dist((r, g, b), background)
            alpha = max(0.0, min(1.0, (distance - 24) / 72))
            if alpha == 0:
                continue
            # Undo the blend with the background at the edges.
            colour = tuple(
                max(0, min(255, round((c - bg * (1 - alpha)) / alpha)))
                for c, bg in zip((r, g, b), background)
            )
            out[x, y] = (*colour, round(alpha * 255))
    box = glyph.getchannel("A").point(lambda a: 255 if a > 127 else 0).getbbox()
    return background, glyph.crop(box)


def scaled(glyph, side):
    """The glyph resized so its longer side is [side] pixels."""
    factor = side / max(glyph.size)
    size = (max(1, round(glyph.width * factor)), max(1, round(glyph.height * factor)))
    return glyph.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def centred(glyph, canvas, glyph_side, background=None):
    image = Image.new("RGBA", (canvas, canvas), (*background, 255) if background else (0, 0, 0, 0))
    resized = scaled(glyph, glyph_side)
    image.alpha_composite(
        resized, ((canvas - resized.width) // 2, (canvas - resized.height) // 2)
    )
    return image


def white(glyph):
    alpha = glyph.getchannel("A")
    image = Image.new("RGBA", glyph.size, (255, 255, 255, 0))
    image.putalpha(alpha)
    return image


def rounded(image, radius_share):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1),
        radius=round(image.width * radius_share),
        fill=255,
    )
    result = image.copy()
    result.putalpha(Image.composite(image.getchannel("A"), mask, mask))
    return result


def legacy(glyph, background, side, shape):
    image = centred(glyph, side * 4, round(side * 4 * LEGACY_GLYPH), background)
    if shape == "round":
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).ellipse((0, 0, image.width - 1, image.height - 1), fill=255)
        image.putalpha(mask)
    else:
        image = rounded(image, 0.18)
    return image.resize((side, side), Image.LANCZOS)


def write(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", type=Path)
    args = parser.parse_args()
    background, glyph = load()
    hex_colour = "#{:02X}{:02X}{:02X}".format(*background)

    outputs = {}
    for density, factor in DENSITIES.items():
        side = round(48 * factor)
        outputs[f"mipmap-{density}/ic_launcher.png"] = legacy(glyph, background, side, "square")
        outputs[f"mipmap-{density}/ic_launcher_round.png"] = legacy(glyph, background, side, "round")
        canvas = round(108 * factor)
        foreground = centred(glyph, canvas, round(ADAPTIVE_GLYPH_DP * factor))
        outputs[f"mipmap-{density}/ic_launcher_foreground.png"] = foreground
        outputs[f"mipmap-{density}/ic_launcher_monochrome.png"] = centred(
            white(glyph), canvas, round(ADAPTIVE_GLYPH_DP * factor)
        )
        outputs[f"drawable-{density}/ic_stat_conest.png"] = centred(
            white(glyph), round(24 * factor), round(STATUS_GLYPH_DP * factor)
        )
    for relative, image in outputs.items():
        write(image, RES / relative)

    adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        path = RES / "mipmap-anydpi-v26" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(adaptive)
    (RES / "values/ic_launcher_background.xml").write_text(
        f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{hex_colour}</color>
</resources>
"""
    )

    desktop = legacy(glyph, background, 1024, "square")
    write(desktop.resize((256, 256), Image.LANCZOS), ROOT / "linux/conest.png")
    desktop.save(
        ROOT / "windows/runner/resources/app_icon.ico",
        sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)],
    )

    if args.preview:
        sheet = Image.new("RGBA", (1100, 420), (40, 40, 48, 255))
        x = 10
        for side in (16, 24, 32, 48, 96, 192):
            sheet.alpha_composite(legacy(glyph, background, side, "square"), (x, 10))
            sheet.alpha_composite(legacy(glyph, background, side, "round"), (x, 220))
            x += side + 20
        # Adaptive icon under a circle and a squircle mask, and themed.
        fg = outputs["mipmap-xxxhdpi/ic_launcher_foreground.png"]
        mono = outputs["mipmap-xxxhdpi/ic_launcher_monochrome.png"]
        for i, (layer, colour) in enumerate(
            ((fg, (*background, 255)), (fg, (*background, 255)), (mono, (60, 70, 50, 255)))
        ):
            base = Image.new("RGBA", fg.size, colour)
            if i == 2:
                tint = Image.new("RGBA", fg.size, (200, 230, 160, 255))
                tint.putalpha(layer.getchannel("A"))
                base.alpha_composite(tint)
            else:
                base.alpha_composite(layer)
            mask = Image.new("L", fg.size, 0)
            draw = ImageDraw.Draw(mask)
            inset = round(fg.width * 18 / 108)
            box = (inset, inset, fg.width - inset - 1, fg.height - inset - 1)
            if i == 1:
                draw.rounded_rectangle(box, radius=round(fg.width * 0.2), fill=255)
            else:
                draw.ellipse(box, fill=255)
            base.putalpha(mask)
            sheet.alpha_composite(base.resize((180, 180), Image.LANCZOS), (560 + i * 180, 10))
        status = outputs["drawable-xxxhdpi/ic_stat_conest.png"]
        sheet.alpha_composite(status, (560, 220))
        write(sheet, args.preview)
    print(f"Icons written (background {hex_colour}).")


if __name__ == "__main__":
    main()
