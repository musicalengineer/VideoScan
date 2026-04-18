#!/usr/bin/env python3
"""
Convert InsightFace ArcFace ONNX model to CoreML .mlpackage.

Usage:
    python3 convert_arcface_coreml.py [--input w600k_r50.onnx] [--output w600k_r50.mlpackage]

Prerequisites:
    pip install coremltools onnx onnx2torch torch

Model download:
    wget https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
    unzip buffalo_l.zip  # contains w600k_r50.onnx (174 MB)
"""

import argparse
import sys

def main():
    parser = argparse.ArgumentParser(description="Convert ArcFace ONNX to CoreML")
    parser.add_argument("--input", default="w600k_r50.onnx", help="Input ONNX model path")
    parser.add_argument("--output", default="w600k_r50.mlpackage", help="Output CoreML path")
    args = parser.parse_args()

    try:
        import torch
        from onnx2torch import convert as onnx2torch_convert
        import coremltools as ct
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with: pip install coremltools onnx onnx2torch torch")
        sys.exit(1)

    print(f"Loading ONNX model: {args.input}")
    torch_model = onnx2torch_convert(args.input)
    torch_model.eval()

    print("Tracing PyTorch model...")
    traced = torch.jit.trace(torch_model, torch.randn(1, 3, 112, 112))

    print("Converting to CoreML...")
    # scale and bias bake in the normalization: (pixel - 127.5) / 127.5
    coreml_model = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="faceImage",
            shape=(1, 3, 112, 112),
            scale=1.0 / 127.5,
            bias=[-1.0, -1.0, -1.0],
            color_layout=ct.colorlayout.RGB,
        )],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )

    coreml_model.save(args.output)
    print(f"Saved CoreML model: {args.output}")

if __name__ == "__main__":
    main()
