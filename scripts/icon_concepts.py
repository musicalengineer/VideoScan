#!/usr/bin/env python3
"""Generate a few macOS-style app icon concepts for VideoScan."""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

SIZE = 1024
OUT_DIR = "/Users/rickb/dev/VideoScan/icon_previews"
APPICON_DIR = "/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Assets.xcassets/AppIcon.appiconset"


def rounded_mask(size, margin=80, radius=190):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius,
        fill=255,
    )
    return mask


def vertical_gradient(size, top_rgb, bottom_rgb):
    img = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(top_rgb[0] * (1 - t) + bottom_rgb[0] * t)
        g = int(top_rgb[1] * (1 - t) + bottom_rgb[1] * t)
        b = int(top_rgb[2] * (1 - t) + bottom_rgb[2] * t)
        d.line([(0, y), (size, y)], fill=(r, g, b, 255))
    return img


def apply_mask(img, mask):
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def add_shadow(base, shape_img, blur=26, offset=(0, 18), alpha=110):
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    a = shape_img.getchannel("A").point(lambda p: min(255, int(p * alpha / 255)))
    shadow.paste((0, 0, 0, 255), offset, a)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    return Image.alpha_composite(base, shadow)


def concept_scan_lens(size=SIZE):
    img = vertical_gradient(size, (25, 36, 62), (13, 20, 34))
    mask = rounded_mask(size)
    img = apply_mask(img, mask)
    d = ImageDraw.Draw(img)

    # Main film card
    card = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    card_rect = [180, 170, 700, 760]
    cd.rounded_rectangle(card_rect, radius=72, fill=(18, 24, 36, 255), outline=(118, 145, 196, 255), width=8)
    for y in (205, 690):
        for x in range(220, 650, 92):
            cd.rounded_rectangle([x, y, x + 34, y + 34], radius=8, fill=(63, 78, 112, 255))
    frame_rect = [240, 250, 640, 642]
    cd.rounded_rectangle(frame_rect, radius=42, fill=(72, 108, 166, 255))
    img = add_shadow(img, card, blur=24, offset=(0, 20), alpha=140)
    img = Image.alpha_composite(img, card)

    # Portrait silhouette
    d = ImageDraw.Draw(img)
    d.ellipse([370, 332, 510, 472], fill=(199, 220, 255, 220))
    d.rounded_rectangle([310, 452, 570, 590], radius=70, fill=(191, 214, 255, 180))

    # Lens
    lens = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lens)
    cx, cy, r = 640, 625, 210
    ld.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(146, 198, 255, 78))
    ld.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(229, 240, 255, 255), width=28)
    ld.arc([cx - r + 25, cy - r + 25, cx + r - 25, cy + r - 25], 197, 278, fill=(255, 255, 255, 170), width=15)
    ld.line([(770, 753), (898, 880)], fill=(196, 166, 108, 255), width=52)
    ld.line([(878, 860), (930, 912)], fill=(136, 109, 65, 255), width=38)
    for i in range(-130, 131, 26):
        y = cy + i
        dy = abs(i)
        inner = r - 28
        if dy >= inner:
            continue
        dx = int(math.sqrt(inner * inner - dy * dy))
        ld.line([(cx - dx, y), (cx + dx, y)], fill=(106, 188, 255, 110), width=2)
    img = add_shadow(img, lens, blur=20, offset=(0, 16), alpha=120)
    img = Image.alpha_composite(img, lens)
    return img


def concept_monogram(size=SIZE):
    img = vertical_gradient(size, (14, 18, 24), (36, 50, 80))
    mask = rounded_mask(size)
    img = apply_mask(img, mask)
    d = ImageDraw.Draw(img)

    # Film border hints
    d.rounded_rectangle([156, 156, 868, 868], radius=170, outline=(109, 134, 184, 255), width=8)
    for y in (204, 790):
        for x in range(230, 770, 100):
            d.rounded_rectangle([x, y, x + 42, y + 32], radius=8, fill=(65, 79, 112, 220))

    # VS monogram
    stroke = 68
    accent = (178, 221, 255, 255)
    d.line([(260, 310), (390, 702)], fill=accent, width=stroke)
    d.line([(390, 702), (520, 310)], fill=accent, width=stroke)

    blue = (133, 187, 255, 255)
    d.arc([510, 286, 792, 510], start=18, end=208, fill=blue, width=stroke)
    d.arc([488, 498, 768, 732], start=202, end=22, fill=blue, width=stroke)

    # Scan bracket around the S
    bracket = (233, 244, 255, 210)
    w = 18
    d.line([(560, 246), (665, 246)], fill=bracket, width=w)
    d.line([(560, 246), (560, 342)], fill=bracket, width=w)
    d.line([(726, 682), (834, 682)], fill=bracket, width=w)
    d.line([(834, 586), (834, 682)], fill=bracket, width=w)
    return img


def concept_reticle(size=SIZE):
    img = vertical_gradient(size, (28, 22, 47), (10, 12, 25))
    mask = rounded_mask(size)
    img = apply_mask(img, mask)
    d = ImageDraw.Draw(img)

    # soft center glow
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([160, 180, 860, 880], fill=(60, 98, 178, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)

    cx, cy, r = 512, 512, 278
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(193, 223, 255, 255), width=22)
    d.ellipse([cx - r + 46, cy - r + 46, cx + r - 46, cy + r - 46], outline=(103, 165, 255, 180), width=8)

    # crosshair ticks
    tick = (198, 228, 255, 230)
    for pts in [
        ((512, 186), (512, 258)),
        ((512, 766), (512, 838)),
        ((186, 512), (258, 512)),
        ((766, 512), (838, 512)),
    ]:
        d.line(pts, fill=tick, width=18)

    # face glyph
    d.ellipse([432, 340, 592, 500], fill=(210, 225, 255, 230))
    d.rounded_rectangle([350, 484, 674, 670], radius=104, fill=(196, 216, 255, 170))

    # subtle scan bars
    for y in range(318, 688, 32):
        d.line([(324, y), (700, y)], fill=(94, 188, 255, 48), width=3)
    return img


def save_resized(master, dest_dir):
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(dest_dir, name))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    concepts = {
        "concept_scan_lens.png": concept_scan_lens(),
        "concept_monogram.png": concept_monogram(),
        "concept_reticle.png": concept_reticle(),
    }
    for name, img in concepts.items():
        img.save(os.path.join(OUT_DIR, name))

    # Install the strongest default into the app icon set.
    save_resized(concepts["concept_scan_lens.png"], APPICON_DIR)
    print(f"Saved previews to {OUT_DIR}")
    print(f"Installed concept_scan_lens into {APPICON_DIR}")


if __name__ == "__main__":
    main()
