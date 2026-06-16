#!/usr/bin/env python3
import cv2
import os
import sys
import subprocess
from pathlib import Path

if len(sys.argv) != 7:
    print("Usage:")
    print("  python remove_timecode.py input.mov output.mov x y w h")
    print()
    print("Example:")
    print("  python remove_timecode.py Donna1991.mov Donna1991_fixed.mov 20 420 250 45")
    sys.exit(1)

input_video = Path(sys.argv[1]).resolve()
output_video = Path(sys.argv[2]).resolve()

x = int(sys.argv[3])
y = int(sys.argv[4])
w = int(sys.argv[5])
h = int(sys.argv[6])

work = output_video.parent / f"{output_video.stem}_work"
frames = work / "frames"
fixed = work / "fixed"
audio = work / "audio.mov"

frames.mkdir(parents=True, exist_ok=True)
fixed.mkdir(parents=True, exist_ok=True)

print("Extracting frames...")
subprocess.run([
    "ffmpeg", "-y",
    "-i", str(input_video),
    str(frames / "frame_%06d.png")
], check=True)

print("Extracting audio...")
subprocess.run([
    "ffmpeg", "-y",
    "-i", str(input_video),
    "-vn",
    "-c:a", "pcm_s24le",
    str(audio)
], check=False)

print("Inpainting frames...")
for frame_path in sorted(frames.glob("frame_*.png")):
    img = cv2.imread(str(frame_path))

    mask = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mask[:] = 0

    # Slightly larger than the timecode box
    pad = 4
    x1 = max(0, x - pad)
    y1 = max(0, y - pad)
    x2 = min(img.shape[1], x + w + pad)
    y2 = min(img.shape[0], y + h + pad)

    mask[y1:y2, x1:x2] = 255

    repaired = cv2.inpaint(img, mask, 5, cv2.INPAINT_TELEA)
    cv2.imwrite(str(fixed / frame_path.name), repaired)

print("Rebuilding video...")
cmd = [
    "ffmpeg", "-y",
    "-framerate", "24000/1001",
    "-i", str(fixed / "frame_%06d.png")
]

if audio.exists():
    cmd += ["-i", str(audio), "-map", "0:v:0", "-map", "1:a:0"]

cmd += [
    "-c:v", "prores_ks",
    "-profile:v", "3",
    "-pix_fmt", "yuv422p10le",
    "-c:a", "copy",
    str(output_video)
]

subprocess.run(cmd, check=True)

print(f"Done: {output_video}")
print(f"Work folder left here: {work}")