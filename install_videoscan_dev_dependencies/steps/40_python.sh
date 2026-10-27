# Step: python — the three venvs the app and scripts look for.
#   venv/            requirements.txt (+ face_recognition_models from git)
#   venv-mlx/        scripts/requirements-mlx.txt  (Whisper transcription, VLM captions)
#   venv-genealogy/  getmyancestors                (Family Tree ▸ FamilySearch pull)
# All built with uv. Existing venvs are reused, never deleted.

section "Python virtual environments"

# make_venv NAME PYTHON — create $REPO_ROOT/NAME with PYTHON unless present.
make_venv() {
    local name="$1" python="$2" dir="$REPO_ROOT/$1"
    if [[ -x "$dir/bin/python" ]]; then
        ok "$name ($("$dir/bin/python" --version 2>&1))"
        return 0
    fi
    if checking; then
        failed "$name" "missing; run without --check to create it with $python"
        return 1
    fi
    if ! command -v "$python" >/dev/null 2>&1; then
        failed "$name" "$python not on PATH (Brewfile installs it; open a new terminal and retry)"
        return 1
    fi
    if uv venv --python "$(command -v "$python")" "$dir" >/dev/null 2>&1; then
        installed "$name ($("$dir/bin/python" --version 2>&1))"
    else
        failed "$name" "run: uv venv --python $python $dir"
        return 1
    fi
}

# pip_into NAME LABEL ARGS… — uv pip install into a venv; quiet unless it fails.
pip_into() {
    local name="$1" label="$2"; shift 2
    local py="$REPO_ROOT/$name/bin/python" log
    log=$(install_log "pip-$name")
    note "installing ${label} into ${name}…"
    if uv pip install --python "$py" "$@" >>"$log" 2>&1; then
        ok "$label in $name"
    else
        failed "$label in $name" "see $log"
    fi
}

# requirements_for NAME LOOSE — the M4's exact versions (locks/NAME.txt) when
# present, else the loose requirements file. The lock is what makes a new Mac
# match the M4 instead of whatever PyPI has that day.
LOCKS="$REPO_ROOT/install_videoscan_dev_dependencies/locks"
requirements_for() {
    if [[ -f "$LOCKS/$1.txt" ]]; then echo "$LOCKS/$1.txt"; else echo "$2"; fi
}

# Not on PyPI and unmaintained upstream; pinned so it can't drift.
FACE_MODELS_GIT="git+https://github.com/ageitgey/face_recognition_models@e67de717267507d1e9246de95692eb8be736ab61"

# check_imports NAME MODULE… — the real test: can the venv import them?
check_imports() {
    local name="$1"; shift
    local py="$REPO_ROOT/$name/bin/python" module bad=()
    [[ -x "$py" ]] || return 0
    for module in "$@"; do
        "$py" -c "import $module" >/dev/null 2>&1 || bad+=("$module")
    done
    if (( ${#bad[@]} == 0 )); then
        ok "$name imports: $*"
    else
        failed "$name imports" "cannot import: ${bad[*]}"
    fi
}

if ! command -v uv >/dev/null 2>&1; then
    failed "uv" "not on PATH; the Brewfile installs it"
else
    # ---- venv (main) ----
    if make_venv venv "$MAIN_PYTHON" && ! checking; then
        # dlib compiles from source (5–10 min the first time).
        reqs=$(requirements_for venv "$REPO_ROOT/requirements.txt")
        pip_into venv "${reqs#"$REPO_ROOT"/}" -r "$reqs"
        # Not on PyPI; carries dlib's face model files.
        pip_into venv "face_recognition_models" --no-deps "$FACE_MODELS_GIT"
    fi
    check_imports venv openpyxl dlib face_recognition torch cv2 sklearn hdbscan pytest shapefile yaml

    # ---- venv-mlx ----
    if make_venv venv-mlx "$MLX_PYTHON" && ! checking; then
        reqs=$(requirements_for venv-mlx "$REPO_ROOT/scripts/requirements-mlx.txt")
        pip_into venv-mlx "${reqs#"$REPO_ROOT"/}" -r "$reqs"
    fi
    check_imports venv-mlx mlx mlx_whisper mlx_vlm

    # ---- venv-genealogy ----
    if make_venv venv-genealogy "$GENEALOGY_PYTHON" && ! checking; then
        reqs=$(requirements_for venv-genealogy "")
        if [[ -n "$reqs" ]]; then
            pip_into venv-genealogy "${reqs#"$REPO_ROOT"/}" -r "$reqs"
        else
            pip_into venv-genealogy "getmyancestors" getmyancestors
        fi
    fi
    if [[ -x "$REPO_ROOT/venv-genealogy/bin/getmyancestors" ]]; then
        ok "getmyancestors (FamilySearch pull)"
    else
        failed "getmyancestors" "missing from venv-genealogy/bin"
    fi
fi
