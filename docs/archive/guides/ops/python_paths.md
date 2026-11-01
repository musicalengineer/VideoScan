<!-- moved from Claude memory (reference_python_paths) on 2026-10-23; operational reference, rewrite in place -->

## Person Finder (dlib engine)

- **Python path:** `/Users/rickb/dev/VideoScan/venv/bin/python3`
- **Script path:** `/Users/rickb/dev/VideoScan/scripts/face_recognize.py`
- **Venv:** `~/dev/VideoScan/venv` (Python 3.14, has dlib/face_recognition, openpyxl)

Auto-detected as defaults and persisted in UserDefaults (pf_ prefix).

## Dossier worker (Qwen + Whisper + OCR)

- **Python path:** `/Users/rickb/dev/VideoScan/venv-mlx/bin/python3` — **NOT the same venv as PersonFinder**
- **Script path:** `/Users/rickb/dev/VideoScan/scripts/dossier_batch.py`
- **Venv:** `~/dev/VideoScan/venv-mlx` (Python 3.12, has `mlx_vlm`, `mlx-whisper`)
- **Same venv layout on all three fleet nodes:** ricksm4.local, ricksm5.local, ricksm1.local
- The script's shebang picks system Python which does NOT have `mlx_vlm` — **always invoke explicitly:** `~/dev/VideoScan/venv-mlx/bin/python3 dossier_batch.py …`

Trip wire fixed 2026-06-07: launching workers without the venv path produces `ModuleNotFoundError: No module named 'mlx_vlm'` and silent failure (the worker exits, no JSONL output, fleet looks stuck). Always include the venv-mlx prefix.

Related: [[project_metadata_dossier_vision]], [[reference_host_fleet_ssh]]
