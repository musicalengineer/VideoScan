# Step: models — ML weights that are NOT in git.
#
#   models/*.mlpackage|.mlmodelc   CoreML face models (ArcFace w600k_r50, AdaFace,
#                                  genderage), ~335 MB, git-ignored. Copied from
#                                  another Mac with --copy-from HOST.
#   ~/.cache/huggingface           mlx-community Whisper + Qwen2.5-VL (--with-models)
#   ~/.ollama                      Hallie's brain qwen3.8:27b-mlx (--with-models)
#
# Big downloads are opt-in so a quick re-run never pulls 20 GB by surprise.

section "Models"

MODELS_DIR="$REPO_ROOT/models"
COREML_MODELS=(w600k_r50 adaface_ir50_webface4m genderage)
HF_MODELS=(mlx-community/whisper-medium-mlx-q4 mlx-community/Qwen2.5-VL-3B-Instruct-4bit)
OLLAMA_BRAIN="qwen3.8:27b-mlx"     # OllamaQueryTranslator.swift default

# ---- CoreML face models ----
coreml_missing=()
for model in "${COREML_MODELS[@]}"; do
    [[ -d "$MODELS_DIR/$model.mlmodelc" ]] || coreml_missing+=("$model")
done
if (( ${#coreml_missing[@]} == 0 )); then
    ok "CoreML face models in models/ (${COREML_MODELS[*]})"
elif [[ -n "$COPY_FROM" ]] && ! checking; then
    # Pull-only copy; the source Mac is never written to.
    note "copying models/ from $COPY_FROM (~335 MB)…"
    mkdir -p "$MODELS_DIR"
    if rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
            "$COPY_FROM:dev/VideoScan/models/" "$MODELS_DIR/"; then
        installed "CoreML face models from $COPY_FROM"
    else
        failed "CoreML face models" "rsync from $COPY_FROM failed (ssh key set up? Remote Login on?)"
    fi
else
    manual "CoreML face models (${coreml_missing[*]})" \
        "not in git; re-run with --copy-from RicksM4.local, or regenerate: scripts/convert_arcface_coreml.py and tools/adaface/convert_adaface_coreml.py"
fi

# ---- Hugging Face (MLX Whisper + VLM) ----
hf_hub="$HOME/.cache/huggingface/hub"
for repo in "${HF_MODELS[@]}"; do
    cache_dir="$hf_hub/models--${repo//\//--}"
    if [[ -d "$cache_dir/snapshots" ]]; then
        ok "HF model $repo"
    elif [[ "$WITH_MODELS" == "1" ]] && ! checking && [[ -x "$REPO_ROOT/venv-mlx/bin/python" ]]; then
        note "downloading $repo…"
        if "$REPO_ROOT/venv-mlx/bin/python" -c \
                "from huggingface_hub import snapshot_download; snapshot_download('$repo')" >/dev/null 2>&1; then
            installed "HF model $repo"
        else
            failed "HF model $repo" "download failed; it will also download on first use"
        fi
    else
        manual "HF model $repo" "downloads on first use, or re-run with --with-models"
    fi
done

# ---- Ollama brain ----
if ! command -v ollama >/dev/null 2>&1; then
    failed "ollama" "not installed (Brewfile installs it)"
else
    # `ollama list` needs a running server; start one briefly if none is up.
    started_server=0
    if ! ollama list >/dev/null 2>&1 && ! checking; then
        ollama serve >/tmp/videoscan-install-ollama.log 2>&1 &
        server_pid=$!
        started_server=1
        for _ in 1 2 3 4 5 6 7 8 9 10; do ollama list >/dev/null 2>&1 && break; sleep 1; done
    fi
    if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$OLLAMA_BRAIN"; then
        ok "Ollama model $OLLAMA_BRAIN"
    elif [[ "$WITH_MODELS" == "1" ]] && ! checking; then
        note "pulling $OLLAMA_BRAIN (~18 GB)…"
        if ollama pull "$OLLAMA_BRAIN"; then
            installed "Ollama model $OLLAMA_BRAIN"
        else
            failed "Ollama model $OLLAMA_BRAIN" "run: ollama pull $OLLAMA_BRAIN"
        fi
    else
        manual "Ollama model $OLLAMA_BRAIN" "Hallie's brain (~18 GB); re-run with --with-models or: ollama pull $OLLAMA_BRAIN"
    fi
    if [[ "$started_server" == "1" ]]; then
        kill "$server_pid" 2>/dev/null || true
    fi
fi
