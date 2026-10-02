# Hallie local neural voice

Hallie can use an optional local Kokoro/MLX speech helper on Apple Silicon. It
runs as a separate process so a speech-model failure cannot crash VideoScan's
catalog or MLX captioning process. If it is absent or fails, Hallie falls back
to an installed Apple voice.

## Install on an M1 through M5 Mac

Prerequisites are macOS 15 or later, Xcode/Swift 6.2, Git, and Git LFS. From a
VideoScan checkout, run:

```sh
bash scripts/install_hallie_kokoro.sh
```

The installer is repeatable and does the following:

- builds the helper and MLX Metal library from pinned Swift package revisions;
- downloads the model and voice data from the pinned `mlalma/KokoroTestApp`
  revision and verifies their SHA-256 checksums;
- performs a real speech-generation smoke test;
- installs under
  `~/Library/Application Support/VideoScan/HallieKokoro`;
- preserves an existing installation as a timestamped `.previous` directory.

No model, generated audio, or build product is stored in Git or in the media
catalog. Installing requires internet access and downloads roughly 350 MB plus
Swift package sources. Normal use is fully local and does not require Ollama.

## Use

Restart VideoScan and open Hallie's settings gear. Enable **Read her answers
aloud**, then select Heart, Bella, Sarah, or Emma. Selecting a voice auditions
it. Hallie displays only a small activity indicator while preparing audio; build
and model diagnostics stay out of the conversation.

This first evaluation helper renders each answer completely before playback,
so short responses may pause for a few seconds. A persistent or streaming
helper is the follow-up if the chosen voice is worth keeping.

## Pinned provenance

- `mlalma/kokoro-ios` 1.0.10 (`9a1e2614e5898106d00eec7fd21ff2fc89d805a6`)
- `mlalma/MisakiSwift` 1.0.5 (`bb5e3e3671ef550dc545a98f4a4c15f58ee649ec`)
- `ml-explore/mlx-swift` 0.29.1 (`072b684acaae80b6a463abab3a103732f33774bf`)
- model source `mlalma/KokoroTestApp`
  (`9dcd3b06468a3c1ecee6d09a33ca687c8e708566`)
- `kokoro-v1_0.safetensors` SHA-256:
  `4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8`
- `voices.npz` SHA-256:
  `56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f`

Kokoro model weights are Apache-2.0 licensed. Review upstream notices before
redistributing an installer or bundling the weights with a release build.
