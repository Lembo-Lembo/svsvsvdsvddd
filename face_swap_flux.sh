#!/usr/bin/env bash
# Minimal installer for custom nodes + model downloads (Runpod-friendly).
# Default: ONLY nodes + models (assumes ComfyUI already installed).
#
# Optional:
#   INSTALL_JUPYTER=1   — install JupyterLab + autostart Jupyter then Comfy
#   INSTALL_TORCH=1     — install/upgrade torch in venv (default: 0 for runpod/pytorch images)
#   FORCE_APT=1         — force apt-get install even if tools exist (default: 0)
#   CLONE_COMFY=1       — clone ComfyUI if missing (default: 0)
#   INSTALL_COMFY_REQ=1 — pip install -r ComfyUI requirements.txt (default: 0)
# Hugging Face (one variable, no duplicates recommended):
#   HF_TOKEN = {{ RUNPOD_SECRET_HF_TOKEN }}
#   (legacy names are mapped to HF_TOKEN: HUGGING_FACE_HUB_TOKEN, HUGGINGFACEHUB_API_TOKEN)
# Environment (defaults):
#   WORKDIR=/workspace
#   COMFY_DIR=$WORKDIR/ComfyUI
#   STATE_DIR=$WORKDIR/.setup_state

set -euo pipefail

WORKDIR="${WORKDIR:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKDIR/ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFY_DIR/venv}"
LOG_DIR="${LOG_DIR:-$WORKDIR/logs}"
STATE_DIR="${STATE_DIR:-$WORKDIR/.setup_state}"
INSTALL_JUPYTER="${INSTALL_JUPYTER:-0}"
INSTALL_TORCH="${INSTALL_TORCH:-0}"
FORCE_APT="${FORCE_APT:-0}"
CLONE_COMFY="${CLONE_COMFY:-0}"
INSTALL_COMFY_REQ="${INSTALL_COMFY_REQ:-0}"

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$WORKDIR" "$STATE_DIR" "$LOG_DIR"

sha_file() {
  local f="$1"
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

stamp_ok() { echo "ok" > "$1"; }
is_ok() { [ -f "$1" ] && grep -q "^ok$" "$1" 2>/dev/null; }

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1
}

need_any_apt() {
  # In runpod/pytorch images most of this already exists.
  # Only apt-get when required tools are missing or forced.
  if [[ "$FORCE_APT" == "1" ]]; then
    return 0
  fi
  need_cmd git || return 0
  need_cmd wget || return 0
  need_cmd python3 || return 0
  need_cmd sha256sum || return 0
  need_cmd awk || return 0
  return 1
}

hf_header_args() {
  # Adds Authorization header if HF_TOKEN is set (for private/gated models).
  if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "--header=Authorization: Bearer ${HF_TOKEN}"
  else
    echo ""
  fi
}

ensure_huggingface_hub() {
  if python -c "import huggingface_hub" >/dev/null 2>&1; then
    return 0
  fi
  python -m pip install -U "huggingface_hub[cli]>=0.24.0"
}

# Download from Hugging Face using hub (uses HF_TOKEN from env).
hf_download_file() {
  local repo_id="$1"
  local filename="$2"
  local dest_file="$3"

  mkdir -p "$(dirname "$dest_file")"
  local tmp="${dest_file}.part"
  rm -f "$tmp"

  python - <<PY
from huggingface_hub import hf_hub_download
import shutil
import os

repo_id = "${repo_id}"
filename = "${filename}"
dest = "${dest_file}"
tmp = "${tmp}"

path = hf_hub_download(repo_id=repo_id, filename=filename)
shutil.copyfile(path, tmp)
os.replace(tmp, dest)
print("OK:", dest)
PY
}

# Prefer hub; optional wget URL as last arg for fallback.
download_model_file() {
  local repo_id="$1" filename="$2" dest_file="$3" url="${4:-}"
  if [[ -s "$dest_file" ]]; then
    return 0
  fi
  if ensure_huggingface_hub && hf_download_file "$repo_id" "$filename" "$dest_file"; then
    return 0
  fi
  if [[ -z "$url" ]]; then
    echo "ERROR: huggingface_hub download failed and no wget URL provided for: $dest_file"
    return 1
  fi
  echo "WARN: falling back to wget for $dest_file"
  local WGET_HF_ARGS
  WGET_HF_ARGS="$(hf_header_args)"
  wget -c $WGET_HF_ARGS -O "${dest_file}.part" "$url"
  mv -f "${dest_file}.part" "$dest_file"
}

# Bash TCP check — no ss/iproute needed
tcp_listening() {
  local host="$1" port="$2"
  bash -lc ">/dev/tcp/${host}/${port}" 2>/dev/null || return 1
}

# ---- HF token normalization (single source: HF_TOKEN) ----
if [[ -z "${HF_TOKEN:-}" && -n "${RUNPOD_SECRET_HF_TOKEN:-}" ]]; then
  export HF_TOKEN="${RUNPOD_SECRET_HF_TOKEN}"
fi
if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  export HF_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
fi
if [[ -z "${HF_TOKEN:-}" && -n "${HUGGINGFACEHUB_API_TOKEN:-}" ]]; then
  export HF_TOKEN="${HUGGINGFACEHUB_API_TOKEN}"
fi
if [[ -n "${HF_TOKEN:-}" ]]; then
  export HF_TOKEN
fi

echo "[1/5] APT (minimal)"
if need_any_apt; then
  if ! is_ok "$STATE_DIR/apt-minimal.ok"; then
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      wget \
      python3 python3-venv python3-pip \
      ffmpeg libgl1 libglib2.0-0 \
      coreutils gawk
    stamp_ok "$STATE_DIR/apt-minimal.ok"
  else
    echo "APT minimal already installed (state: $STATE_DIR/apt-minimal.ok)"
  fi
else
  echo "Skipping apt-get: required tools already present (FORCE_APT=0)"
fi

cd "$WORKDIR"

echo "[2/5] ComfyUI check"
if [ ! -d "$COMFY_DIR" ]; then
  if [[ "$CLONE_COMFY" == "1" ]]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
  else
    echo "ERROR: COMFY_DIR not found: $COMFY_DIR"
    echo "Set COMFY_DIR or run with CLONE_COMFY=1."
    exit 2
  fi
else
  echo "Using existing ComfyUI dir: $COMFY_DIR"
fi

echo "[3/5] venv + torch + comfy requirements"
cd "$COMFY_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip wheel setuptools

if python -c "import torch, torchvision, torchaudio" >/dev/null 2>&1; then
  echo "Torch already importable, skip torch install"
else
  if [[ "$INSTALL_TORCH" == "1" ]]; then
    if ! python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128; then
      echo "WARN: CUDA wheels failed, trying default pip index..."
      python -m pip install torch torchvision torchaudio
    fi
  else
    echo "Torch not importable, but INSTALL_TORCH=0; skipping torch install"
    echo "Set INSTALL_TORCH=1 to install it inside the venv."
  fi
fi

REQ_SHA="$(sha_file "$COMFY_DIR/requirements.txt")"
REQ_STAMP="$STATE_DIR/comfy_requirements.sha"
if [[ "$INSTALL_COMFY_REQ" == "1" ]]; then
  if [ -n "$REQ_SHA" ] && [ -f "$REQ_STAMP" ] && grep -q "^$REQ_SHA$" "$REQ_STAMP"; then
    echo "ComfyUI requirements unchanged, skip pip -r"
  else
    python -m pip install -r requirements.txt
    echo "$REQ_SHA" > "$REQ_STAMP"
  fi
else
  echo "Skipping ComfyUI requirements (INSTALL_COMFY_REQ=0)"
fi

echo "[4/5] Custom nodes"
mkdir -p "$COMFY_DIR/custom_nodes"
cd "$COMFY_DIR/custom_nodes"

if [ ! -d rgthree-comfy/.git ]; then
  git clone https://github.com/rgthree/rgthree-comfy.git
fi
if [ ! -d ComfyUI-Easy-Use/.git ]; then
  git clone https://github.com/yolain/ComfyUI-Easy-Use.git
fi

for d in rgthree-comfy ComfyUI-Easy-Use; do
  if [ -f "$d/requirements.txt" ]; then
    NODE_SHA="$(sha_file "$d/requirements.txt")"
    NODE_STAMP="$STATE_DIR/node_${d}_requirements.sha"
    if [ -n "$NODE_SHA" ] && [ -f "$NODE_STAMP" ] && grep -q "^$NODE_SHA$" "$NODE_STAMP"; then
      echo "Node $d requirements unchanged, skip"
    else
      python -m pip install -r "$d/requirements.txt"
      echo "$NODE_SHA" > "$NODE_STAMP"
    fi
  fi
done

echo "[5/5] Models (huggingface_hub + HF_TOKEN; wget fallback)"
mkdir -p "$COMFY_DIR/models/diffusion_models" \
         "$COMFY_DIR/models/text_encoders" \
         "$COMFY_DIR/models/vae"

download_model_file \
  "Comfy-Org/vae-text-encorder-for-flux-klein-9b" \
  "split_files/text_encoders/qwen_3_8b.safetensors" \
  "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors" \
  "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"

download_model_file \
  "Comfy-Org/flux2-dev" \
  "split_files/vae/flux2-vae.safetensors" \
  "$COMFY_DIR/models/vae/flux2-vae.safetensors" \
  "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"

# -------- Optional Jupyter --------
if [[ "$INSTALL_JUPYTER" == "1" ]]; then
  echo "[extra] JupyterLab"
  if ! python -c "import jupyterlab, notebook, ipykernel" >/dev/null 2>&1; then
    python -m pip install jupyterlab notebook ipykernel
  fi
  mkdir -p /root/.jupyter
  cat > /root/.jupyter/jupyter_lab_config.py <<'EOF'
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.disable_check_xsrf = True
EOF
fi

# -------- Autostart --------
echo "Autostart:"
if [[ "$INSTALL_JUPYTER" == "1" ]]; then
  if tcp_listening 127.0.0.1 8888; then
    echo "Port 8888 already in use, skip JupyterLab start"
  else
    nohup bash -lc "
      source \"$VENV_DIR/bin/activate\"
      jupyter lab --config=/root/.jupyter/jupyter_lab_config.py
    " > "$LOG_DIR/jupyter.log" 2>&1 &
  fi
  sleep 2
fi

if tcp_listening 127.0.0.1 8188; then
  echo "Port 8188 already in use, skip ComfyUI start"
else
  nohup bash -lc "
    cd \"$COMFY_DIR\"
    source \"$VENV_DIR/bin/activate\"
    python main.py --listen 0.0.0.0 --port 8188 --disable-auto-launch --enable-cors-header
  " > "$LOG_DIR/comfyui.log" 2>&1 &
fi

echo "--------------------------------------"
echo "ComfyUI: http://SERVER_IP:8188"
[[ "$INSTALL_JUPYTER" == "1" ]] && echo "JupyterLab: http://SERVER_IP:8888"
echo "Logs: $LOG_DIR"
echo "--------------------------------------"
