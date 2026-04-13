# Issue #6: Custom Face Recognition Model Training on Family Media

## Problem

Generic pre-trained face recognition models (Vision framework, dlib's `dlib_face_recognition_resnet_model_v1`) are trained on celebrity/web-scraped datasets that may not represent the lighting, camera quality, and age progression found in decades of family home video. A model fine-tuned on your specific family could significantly improve accuracy.

## Why This Could Work

1. **Domain shift:** Family video from the 1980s-2000s has very different characteristics than modern HD — interlaced video, poor lighting, analog artifacts, VHS-quality resolution. A fine-tuned model would learn these patterns.

2. **Closed-world recognition:** You're not trying to recognize arbitrary faces — just a known set of family members. This is a much easier problem that can achieve very high accuracy with relatively little training data.

3. **Age progression:** A model trained on photos of Donna from the 1980s through 2020s would learn her age-specific features, whereas a generic model treats each decade as a different-looking person.

## Approach Options

### Option A: Fine-tune ArcFace/FaceNet embedding model (Recommended)

**What:** Take a pre-trained face embedding model and fine-tune it on family photos so it produces embeddings that cluster family members more tightly.

**How:**
1. Collect 20-50 reference photos per family member across different ages/conditions
2. Use a pre-trained ArcFace or FaceNet model (PyTorch or TensorFlow)
3. Fine-tune the last few layers using triplet loss or ArcFace loss
4. Export to CoreML format for on-device inference

**Tools:**
- `insightface` Python library (ArcFace models, easy fine-tuning)
- PyTorch + `facenet-pytorch` (FaceNet with fine-tuning support)
- `coremltools` to convert the trained model to `.mlmodel`

**Training data needed:** 20-50 images per person (can be extracted from videos where you've already confirmed identity)

**Training time:** ~30 minutes on M4 Max (GPU via MPS)

```python
# Rough workflow
import torch
from facenet_pytorch import InceptionResnetV1

# Load pre-trained
model = InceptionResnetV1(pretrained='vggface2')

# Freeze early layers, fine-tune last 2 blocks
for param in model.parameters():
    param.requires_grad = False
for param in model.last_linear.parameters():
    param.requires_grad = True
for param in model.last_bn.parameters():
    param.requires_grad = True

# Train with triplet loss on family photos
# ... (anchor=person, positive=same person different photo, negative=different person)

# Export to CoreML
import coremltools as ct
traced = torch.jit.trace(model.eval(), torch.randn(1, 3, 160, 160))
mlmodel = ct.convert(traced, inputs=[ct.TensorType(shape=(1, 3, 160, 160))])
mlmodel.save("FamilyFaceNet.mlmodel")
```

### Option B: Few-shot learning with prototypical networks

**What:** Train a small network that learns to compare faces using only a few examples per person. Better when you have limited reference photos.

**How:**
- Use a prototypical network or siamese network architecture
- Train on "episodes" — each episode samples a few examples per person and learns to classify
- Works well with as few as 5 photos per person

**Advantage:** More robust when reference photos are scarce
**Disadvantage:** Slightly lower accuracy ceiling than fine-tuned ArcFace

### Option C: Embedding + classifier hybrid

**What:** Use the existing Vision framework face embeddings but train a lightweight classifier (SVM or small neural net) on top.

**How:**
1. Extract Vision framework feature prints for all known-identity faces
2. Train an SVM or small MLP to map feature prints → person labels
3. At inference time, extract Vision feature print → classify with trained model

**Advantage:** No model conversion needed, stays within Apple's ecosystem
**Disadvantage:** Limited by Vision's embedding quality on old video

## Integration with VideoScan

The trained CoreML model would slot into the existing pluggable engine architecture:

```swift
case .customModel:
    // Load the family-specific CoreML model
    let model = try FamilyFaceNet(configuration: .init())
    // Extract face region, resize to 160x160
    // Run inference to get embedding
    // Compare embedding distance to reference embeddings
```

This becomes a new `FaceDetectionEngine` case alongside `.vision`, `.dlib`, and `.hybrid`.

## Training Pipeline Proposal

1. **Bootstrap phase:** Use existing Vision-based detections to auto-extract training faces from videos where identity is already confirmed
2. **Curation:** Quick manual review UI — show detected faces, confirm/reject identity labels
3. **Training:** Run fine-tuning script (Python, ~30 min on M4 Max)
4. **Deployment:** Convert to CoreML, bundle with app or load from `~/dev/VideoScan/models/`
5. **Iterate:** As more videos are processed and confirmed, retrain periodically for better accuracy

## Is This Novel?

Fine-tuning face recognition models isn't new, but applying it specifically to **decades of family home video** with age progression, analog artifacts, and a closed-world assumption is an underexplored niche. Most face recognition research focuses on surveillance (high-res, modern cameras) or social media (well-lit selfies). The family video domain has unique challenges that a purpose-trained model could address better than any off-the-shelf solution.

## Effort Estimate

- **Option A (ArcFace fine-tune):** 2-3 days for the training pipeline, 1 day for CoreML integration
- **Option B (few-shot):** 3-4 days, more experimental
- **Option C (Vision + SVM):** 1 day, least effort but lowest improvement ceiling

## Recommendation

Start with **Option C** (Vision embeddings + SVM classifier) as a quick experiment to quantify how much a trained classifier improves over raw distance thresholds. If the improvement is significant (>10% accuracy gain), invest in **Option A** for the full fine-tuned model.
