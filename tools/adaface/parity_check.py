#!/usr/bin/env python3
"""Numerical parity gate for the AdaFace CoreML conversion (GH #144).

For each test image: run the PyTorch checkpoint and the converted CoreML
model on the SAME 112x112 crop and require cosine(pt, coreml) >= 0.999.

The two paths deliberately exercise the two halves of the preprocessing
contract:
  PyTorch : PIL RGB -> numpy -> BGR -> (x/255-0.5)/0.5   (inference.py exact)
  CoreML  : PIL RGB image handed to coremltools predict — the model's baked
            ImageType(BGR, scale, bias) must reproduce the same normalization.
A channel-order or normalization mistake in the conversion shows up here as
cosine ~0.5-0.9, not 0.999+.

Usage:
  python tools/adaface/parity_check.py \
      --ckpt ... --mlpackage models/adaface_ir50_webface4m.mlpackage \
      --images tests/fixtures/photos [--min-cosine 0.9985]

Gate defaults to 0.9985 — the DEPLOYED artifact is fp16 (same precision as
the ArcFace package) and fp16 weight quantization alone costs up to ~0.001
cosine (observed min 0.998992 across 30 fixtures), so the shipped model must
not exit 1 against its own gate. When verifying the conversion PIPELINE with
an fp32 build (convert_adaface_coreml.py --precision fp32), pass
--min-cosine 0.999 — fp32 parity is ~1.000000 and anything below 0.999 there
means a real preprocessing/channel-order bug, not quantization.

Exit code 0 = all images pass; 1 = any failure (CI-friendly).
"""

import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
import torch  # noqa: E402
from PIL import Image  # noqa: E402

from convert_adaface_coreml import load_backbone  # noqa: E402

IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".bmp", ".tiff")


def torch_embedding(model: torch.nn.Module, pil_rgb: Image.Image) -> np.ndarray:
    np_img = np.array(pil_rgb)
    bgr = ((np_img[:, :, ::-1] / 255.0) - 0.5) / 0.5          # inference.py exact
    tensor = torch.tensor(bgr.transpose(2, 0, 1)[None]).float()
    with torch.no_grad():
        feature, _ = model(tensor)
    return feature.numpy().ravel()


def coreml_embedding(mlmodel, pil_rgb: Image.Image) -> np.ndarray:
    out = mlmodel.predict({"faceImage": pil_rgb})
    return np.asarray(out["embedding"]).ravel()


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--mlpackage", required=True)
    ap.add_argument("--images", required=True, help="dir of test images")
    ap.add_argument("--min-cosine", type=float, default=0.9985,
                    help="fp16 deployed gate; use 0.999 for fp32 pipeline verification")
    args = ap.parse_args()

    import coremltools as ct
    model = load_backbone(args.ckpt)
    # CPU_ONLY for deterministic fp comparison (ANE fp16 scheduling varies).
    mlmodel = ct.models.MLModel(
        args.mlpackage, compute_units=ct.ComputeUnit.CPU_ONLY)

    paths = sorted(p for p in glob.glob(os.path.join(args.images, "*"))
                   if p.lower().endswith(IMAGE_EXTS))
    if not paths:
        print(f"FAIL: no test images in {args.images}")
        sys.exit(1)

    failures = 0
    for p in paths:
        pil = Image.open(p).convert("RGB").resize((112, 112), Image.BILINEAR)
        c = cosine(torch_embedding(model, pil), coreml_embedding(mlmodel, pil))
        status = "ok " if c >= args.min_cosine else "FAIL"
        if c < args.min_cosine:
            failures += 1
        print(f"{status} cosine={c:.6f}  {os.path.basename(p)}")

    print(f"\n{len(paths) - failures}/{len(paths)} passed (gate {args.min_cosine})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
