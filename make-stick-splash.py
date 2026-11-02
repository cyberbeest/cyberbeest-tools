#!/usr/bin/env python3
"""Renders the boot-menu background of the Cyberbeest stick (replaces the live image's
Debian splash): logo, stick name and a short description in the top part, the menu area
below left empty. combine-live-and-installer.sh swaps the results in for
/boot/grub/splash.png (1366x768, the panels' native 16:9; GRUB runs at the screen's own
mode and pads other shapes) and /isolinux/splash.png (640x480, BIOS boot).

    python3 make-stick-splash.py [OUT_DIR]     (default: stick-splash/ next to this script)

To rename the stick or reword the description, edit TEXT below and re-run; the PNGs in
stick-splash/ are committed so the release build needs no image tooling.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = os.path.join(HERE, "..", "provisioning", "lib", "plymouth-theme", "watermark.png")
FONT_BOLD = "/usr/share/fonts/truetype/lato/Lato-Bold.ttf"
FONT_TEXT = "/usr/share/fonts/truetype/lato/Lato-Medium.ttf"

WHITE = (255, 255, 255)
TEAL = (40, 215, 190)
GRAY = (170, 178, 180)

# (first word in white, rest in teal), then the description lines.
TEXT = {
    "en": (("Cyberbeest", "Stick"),
           ["Scan this computer for malware,", "try Cyberbeest, or install it."]),
    "de": (("Cyberbeest", "Stick"),
           ["Diesen Computer auf Schadsoftware prüfen,", "Cyberbeest ausprobieren oder installieren."]),
}

# size -> (logo px, title px, text px, left margin, top margin); the grub menu starts at
# 52% of the height, the isolinux menu at about row 12 of 30, so everything fits above that.
LAYOUT = {
    (1366, 768): (300, 62, 28, 150, 50),
    (640, 480): (160, 36, 17, 36, 18),
}


def render(size, lang):
    w, h = size
    logo_px, title_px, text_px, left, top = LAYOUT[size]
    img = Image.new("RGB", size, (0, 0, 0))
    logo = Image.open(LOGO).convert("RGB").resize((logo_px, logo_px), Image.LANCZOS)
    img.paste(logo, (left, top))

    draw = ImageDraw.Draw(img)
    (first, rest), lines = TEXT[lang]
    f_title = ImageFont.truetype(FONT_BOLD, title_px)
    f_text = ImageFont.truetype(FONT_TEXT, text_px)
    x = left + logo_px + left // 2 + 10
    block = int(title_px * 1.5) + int(text_px * 1.45) * len(lines)
    y = top + (logo_px - block) // 2
    draw.text((x, y), first, font=f_title, fill=WHITE)
    draw.text((x + draw.textlength(first + " ", font=f_title), y), rest, font=f_title, fill=TEAL)
    y += int(title_px * 1.5)
    for line in lines:
        draw.text((x, y), line, font=f_text, fill=GRAY)
        y += int(text_px * 1.45)
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "stick-splash")
    os.makedirs(out, exist_ok=True)
    for size, kind in (((1366, 768), "grub"), ((640, 480), "isolinux")):
        for lang in TEXT:
            path = os.path.join(out, f"splash-{kind}-{lang}.png")
            render(size, lang).save(path, optimize=True)
            print(path)


main()
