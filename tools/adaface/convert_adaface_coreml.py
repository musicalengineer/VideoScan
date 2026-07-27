#!/usr/bin/env python3
"""Convert the AdaFace IR-50 (WebFace4M) checkpoint to CoreML (GH #144).

Produces adaface_ir50_webface4m.mlpackage with the SAME I/O contract as the
ArcFace w600k_r50 package the app already ships:

  input : "faceImage"  — 112x112 color image
  output: "embedding"  — 512-d float MultiArray (unnormalized; the Swift
                          side L2-normalizes before cosine, same as ArcFace)

Preprocessing is baked into the model so the Swift feed path is identical to
ArcFace's (a plain 112x112 RGB CVPixelBuffer):

  AdaFace canonical (inference.py): BGR, (x/255 - 0.5)/0.5
  =>  ImageType(color_layout=BGR, scale=2/255, bias=[-1,-1,-1])
  CoreML performs the RGB->BGR swap + affine normalization internally.

Usage:
  python tools/adaface/convert_adaface_coreml.py \
      --ckpt /path/to/adaface_ir50_webface4m.ckpt \
      --out  models/adaface_ir50_webface4m.mlpackage

Checkpoint provenance: mk-minchul/AdaFace README, IR-50 / WebFace4M,
Google Drive id 1BmDRrhPsHSbXcWZoYFPJg2KJn1sd3QpN,
sha256 52cca7c64808fea6f44f9b9aee2b0e091bf96c1ab4f6e31bedcdf5d77009b4f8.
Code MIT; WebFace4M training data is research-use — do not redistribute
the converted model. See docs/design/adaface-plugin.md.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import torch  # noqa: E402
import adaface_net  # noqa: E402  (vendored net.py, MIT)

MODEL_VERSION = "adaface-ir50wf4m-v1"


class EmbeddingOnly(torch.nn.Module):
    """AdaFace's forward returns (embedding, norm); CoreML wants one tensor."""

    def __init__(self, backbone):
        super().__init__()
        self.backbone = backbone

    def forward(self, x):
        feature, _ = self.backbone(x)
        return feature


def load_backbone(ckpt_path: str) -> torch.nn.Module:
    model = adaface_net.build_model("ir_50")
    # Lightning checkpoint: tensors live under 'state_dict' with 'model.'
    # prefixes. weights_only=False because the ckpt pickles trainer state;
    # provenance/sha256 of the file is pinned in the module docstring.
    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = {k[len("model."):]: v for k, v in ckpt["state_dict"].items()
             if k.startswith("model.")}
    model.load_state_dict(state)
    model.eval()
    return model


def convert(ckpt_path: str, out_path: str, precision: str = "fp16") -> None:
    import coremltools as ct

    wrapped = EmbeddingOnly(load_backbone(ckpt_path)).eval()
    example = torch.rand(1, 3, 112, 112)  # post-preprocessing range irrelevant for trace
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    # fp16 is the deployed precision (matches the ArcFace w600k_r50 package,
    # ANE-friendly, 83 MB). fp32 exists to VERIFY the conversion pipeline:
    # at fp32 parity vs PyTorch is ~0.99999+, proving any fp16 shortfall is
    # weight quantization, not a preprocessing/channel-order bug.
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        compute_precision=(ct.precision.FLOAT32 if precision == "fp32"
                           else ct.precision.FLOAT16),
        minimum_deployment_target=ct.target.macOS13,
        inputs=[ct.ImageType(
            name="faceImage",
            shape=(1, 3, 112, 112),
            color_layout=ct.colorlayout.BGR,   # AdaFace canonical channel order
            scale=2.0 / 255.0,                 # (x/255 - 0.5)/0.5
            bias=[-1.0, -1.0, -1.0],
        )],
        outputs=[ct.TensorType(name="embedding")],
    )
    mlmodel.short_description = (
        "AdaFace IR-50 (WebFace4M) face identity embedding, 512-d. "
        "CVPR 2022, mk-minchul/AdaFace (MIT). Research-use training data."
    )
    mlmodel.version = MODEL_VERSION
    mlmodel.author = "Kim et al., AdaFace (converted for VideoScan)"
    mlmodel.license = "Code MIT; WebFace4M checkpoint research-use only"
    mlmodel.save(out_path)
    print(f"saved {out_path}")
    print(f"torch={torch.__version__} coremltools={ct.__version__}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True, help="adaface_ir50_webface4m.ckpt path")
    ap.add_argument("--out", required=True, help="output .mlpackage path")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    args = ap.parse_args()
    convert(args.ckpt, args.out, args.precision)


if __name__ == "__main__":
    main()
