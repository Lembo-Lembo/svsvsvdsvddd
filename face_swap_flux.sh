#!/usr/bin/env bash
# Minimal ComfyUI + custom nodes + model downloads (optional Jupyter).
# Default: ONLY Comfy + nodes + models. No Jupyter, no htop/tmux/etc.
#
# Optional:
#   INSTALL_JUPYTER=1   — install JupyterLab + autostart Jupyter then Comfy
#   INSTALL_TORCH=1     — install/upgrade torch in venv (default: 0 for runpod/pytorch images)
#   FORCE_APT=1         — force apt-get install even if tools exist (default: 0)
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

# Bash TCP check — no ss/iproute needed
tcp_listening() {
  local host="$1" port="$2"
  bash -lc ">/dev/tcp/${host}/${port}" 2>/dev/null || return 1
}

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

echo "[2/5] ComfyUI clone"
if [ ! -d "$COMFY_DIR/.git" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "ComfyUI repo exists: $COMFY_DIR"
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
if [ -n "$REQ_SHA" ] && [ -f "$REQ_STAMP" ] && grep -q "^$REQ_SHA$" "$REQ_STAMP"; then
  echo "ComfyUI requirements unchanged, skip pip -r"
else
  python -m pip install -r requirements.txt
  echo "$REQ_SHA" > "$REQ_STAMP"
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

echo "[5/5] Models (wget only if file missing)"
mkdir -p "$COMFY_DIR/models/diffusion_models" \
         "$COMFY_DIR/models/text_encoders" \
         "$COMFY_DIR/models/vae"

if [ ! -s "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors" ]; then
  wget -c -O "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors.part" \
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"
  mv -f "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors.part" \
    "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors"
fi

if [ ! -s "$COMFY_DIR/models/vae/flux2-vae.safetensors" ]; then
  wget -c -O "$COMFY_DIR/models/vae/flux2-vae.safetensors.part" \
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
  mv -f "$COMFY_DIR/models/vae/flux2-vae.safetensors.part" \
    "$COMFY_DIR/models/vae/flux2-vae.safetensors"
fi

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
