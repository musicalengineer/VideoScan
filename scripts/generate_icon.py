#!/usr/bin/env python3
"""Generate VideoScan app icon — film frame + magnifying glass."""

from PIL import Image, ImageDraw, ImageFont
import math, os

SIZE = 1024  # Master size, we'll scale down for all variants

def draw_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size  # shorthand

    # --- Background: rounded rectangle with dark blue-gray gradient ---
    # We'll fake a gradient with horizontal bands
    margin = int(s * 0.08)
    corner = int(s * 0.18)

    # Draw gradient background
    for y in range(margin, s - margin):
        t = (y - margin) / (s - 2 * margin)
        r = int(30 + t * 15)
        g = int(35 + t * 20)
        b = int(55 + t * 35)
        d.line([(margin, y), (s - margin - 1, y)], fill=(r, g, b, 255))

    # Mask to rounded rect
    mask = Image.new("L", (s, s), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([margin, margin, s - margin, s - margin], radius=corner, fill=255)
    img.putalpha(mask)

    # --- Film strip (left-center area) ---
    film_left = int(s * 0.12)
    film_top = int(s * 0.18)
    film_right = int(s * 0.72)
    film_bottom = int(s * 0.82)
    film_w = film_right - film_left
    film_h = film_bottom - film_top

    # Film body
    d.rounded_rectangle([film_left, film_top, film_right, film_bottom],
                        radius=int(s * 0.03), fill=(20, 20, 30, 255),
                        outline=(100, 110, 140, 255), width=max(2, int(s * 0.004)))

    # Sprocket holes - top row
    sprocket_size = int(s * 0.028)
    sprocket_margin = int(s * 0.02)
    sprocket_y_top = film_top + sprocket_margin
    sprocket_y_bot = film_bottom - sprocket_margin - sprocket_size
    num_sprockets = 7
    for i in range(num_sprockets):
        x = film_left + int(s * 0.04) + i * int(film_w * 0.13)
        if x + sprocket_size > film_right - int(s * 0.02):
            break
        d.rounded_rectangle([x, sprocket_y_top, x + sprocket_size, sprocket_y_top + sprocket_size],
                            radius=max(1, int(s * 0.005)), fill=(50, 55, 75, 255))
        d.rounded_rectangle([x, sprocket_y_bot, x + sprocket_size, sprocket_y_bot + sprocket_size],
                            radius=max(1, int(s * 0.005)), fill=(50, 55, 75, 255))

    # Film frames (3 frames visible)
    frame_margin_x = int(s * 0.05)
    frame_margin_y = int(s * 0.065)
    inner_top = film_top + frame_margin_y
    inner_bot = film_bottom - frame_margin_y
    frame_gap = int(s * 0.015)

    num_frames = 3
    total_gap = frame_gap * (num_frames - 1)
    avail_w = film_w - 2 * frame_margin_x - total_gap
    fw = avail_w // num_frames

    frame_colors = [
        (60, 80, 120, 255),   # blue-ish
        (70, 100, 90, 255),   # teal-ish
        (80, 70, 100, 255),   # purple-ish
    ]

    for i in range(num_frames):
        fx = film_left + frame_margin_x + i * (fw + frame_gap)
        d.rounded_rectangle([fx, inner_top, fx + fw, inner_bot],
                            radius=max(1, int(s * 0.01)),
                            fill=frame_colors[i],
                            outline=(90, 100, 130, 200), width=max(1, int(s * 0.002)))

        # Little "scene" elements in each frame
        cx = fx + fw // 2
        cy = inner_top + (inner_bot - inner_top) // 2

        if i == 0:
            # Simple person silhouette
            head_r = int(fw * 0.12)
            d.ellipse([cx - head_r, cy - int(fw * 0.22) - head_r,
                       cx + head_r, cy - int(fw * 0.22) + head_r],
                      fill=(90, 120, 170, 200))
            d.ellipse([cx - int(fw * 0.2), cy - int(fw * 0.05),
                       cx + int(fw * 0.2), cy + int(fw * 0.25)],
                      fill=(90, 120, 170, 200))
        elif i == 1:
            # Play triangle
            tri_s = int(fw * 0.2)
            d.polygon([(cx - tri_s//2, cy - tri_s),
                       (cx - tri_s//2, cy + tri_s),
                       (cx + tri_s, cy)],
                      fill=(110, 150, 130, 200))
        else:
            # Star/sparkle
            star_r = int(fw * 0.15)
            for angle in range(0, 360, 45):
                rad = math.radians(angle)
                r = star_r if angle % 90 == 0 else star_r // 2
                ex = cx + int(r * math.cos(rad))
                ey = cy + int(r * math.sin(rad))
                d.line([(cx, cy), (ex, ey)], fill=(140, 120, 160, 200),
                       width=max(1, int(s * 0.004)))

    # --- Magnifying glass (lower-right, overlapping film) ---
    mag_cx = int(s * 0.68)
    mag_cy = int(s * 0.65)
    mag_r = int(s * 0.18)
    ring_w = max(3, int(s * 0.025))

    # Glass body (semi-transparent light blue)
    d.ellipse([mag_cx - mag_r, mag_cy - mag_r, mag_cx + mag_r, mag_cy + mag_r],
              fill=(140, 180, 230, 80))

    # Glass ring
    d.ellipse([mag_cx - mag_r, mag_cy - mag_r, mag_cx + mag_r, mag_cy + mag_r],
              outline=(200, 215, 240, 255), width=ring_w)

    # Highlight arc on glass
    highlight_r = mag_r - int(s * 0.02)
    d.arc([mag_cx - highlight_r, mag_cy - highlight_r,
           mag_cx + highlight_r, mag_cy + highlight_r],
          start=200, end=280, fill=(220, 235, 255, 150), width=max(2, int(s * 0.008)))

    # Handle
    handle_angle = math.radians(45)
    hx1 = mag_cx + int((mag_r - ring_w//2) * math.cos(handle_angle))
    hy1 = mag_cy + int((mag_r - ring_w//2) * math.sin(handle_angle))
    handle_len = int(s * 0.18)
    hx2 = hx1 + int(handle_len * math.cos(handle_angle))
    hy2 = hy1 + int(handle_len * math.sin(handle_angle))

    handle_w = max(4, int(s * 0.04))
    d.line([(hx1, hy1), (hx2, hy2)], fill=(160, 140, 110, 255), width=handle_w)
    # Handle grip
    grip_len = int(handle_len * 0.4)
    gx1 = hx2 - int(grip_len * 0.3 * math.cos(handle_angle))
    gy1 = hy2 - int(grip_len * 0.3 * math.sin(handle_angle))
    d.line([(gx1, gy1), (hx2, hy2)], fill=(130, 110, 80, 255), width=handle_w + max(2, int(s * 0.01)))

    # --- Scan lines inside magnifying glass ---
    for i in range(-mag_r + int(s*0.04), mag_r, int(s * 0.025)):
        ly = mag_cy + i
        # Find x extent of circle at this y
        dy = abs(i)
        if dy >= mag_r - ring_w:
            continue
        dx = int(math.sqrt((mag_r - ring_w)**2 - dy**2))
        lx1 = mag_cx - dx
        lx2 = mag_cx + dx
        alpha = 60 + int(30 * (1 - abs(i) / mag_r))
        d.line([(lx1, ly), (lx2, ly)], fill=(100, 200, 255, alpha), width=1)

    return img


# Generate master and all required sizes
master = draw_icon(SIZE)

icon_dir = "/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Assets.xcassets/AppIcon.appiconset"

# macOS icon sizes: 16, 32, 128, 256, 512 at 1x and 2x
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
    resized = master.resize((px, px), Image.LANCZOS)
    resized.save(os.path.join(icon_dir, name))
    print(f"  Saved {name} ({px}x{px})")

print("Done! All icon sizes generated.")
