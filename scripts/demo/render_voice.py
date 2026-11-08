"""Render the demo tour's narration in Hallie's voice (Kokoro, af_heart) into
the ignored .scratch/demo/voice/, where demo_tour.js plays it with afplay.

  python3 scripts/demo/render_voice.py
Needs Hallie's Kokoro install (Settings ▸ Hallie ▸ voice). Local only.
"""
import pathlib, shutil, subprocess, sys

REPO = pathlib.Path(__file__).resolve().parents[2]
INST = pathlib.Path.home() / "Library/Application Support/VideoScan/HallieKokoro"
OUT = REPO / ".scratch/demo/voice"

LINES = {
    "intro":   "Hi Dan. Claude would like to give you a demo of VideoScan.",
    "people":  "People. Who the machine has found in the footage.",
    "catalog": "The catalog. Every family media file, on every drive.",
    "folders": "The catalog as folders. Events and copies, grouped.",
    "storage": "Storage. Every drive, its role, and its health.",
    "triage":  "Triage. What still needs a look.",
    "archive": "The archive. The keepers, filed by decade.",
    "tree":    "The family tree.",
    "walk":    "Walking the family tree.",
    "map":     "And where they were born, on the map.",
    "search":  "Now, a search by picture. Let's ask the machine for baseball, using only what it sees in the frames.",
    "found":   "No filenames, no tags. Just what the model saw.",
    "end":     "That's the demo. Claude is done. Rick, you can take over now.",
}


def main() -> int:
    if not (INST / "kokoro-tts").exists():
        print(f"Kokoro not installed at {INST}", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for key, text in LINES.items():
        tmp = OUT / ("tmp-" + key)
        tmp.mkdir(exist_ok=True)
        subprocess.run([str(INST / "kokoro-tts"), "--model", str(INST / "kokoro-v1_0.safetensors"),
                        "--voices", str(INST / "voices.npz"), "--output", str(tmp), "--voice", "af_heart",
                        "--speed", "1.0", "--text", text],
                       capture_output=True, text=True, cwd=str(INST), timeout=120, check=True)
        wav = next(tmp.glob("*.wav"))
        shutil.move(str(wav), OUT / (key + ".wav"))
        tmp.rmdir()
        print(key, "ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
