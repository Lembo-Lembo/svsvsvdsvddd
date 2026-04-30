#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKDIR/ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFY_DIR/venv}"
LOG_DIR="${LOG_DIR:-$WORKDIR/logs}"
STATE_DIR="${STATE_DIR:-$WORKDIR/.setup_state}"

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$WORKDIR" "$STATE_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

sha_file() {
  # prints sha256 of file, or empty if missing
  local f="$1"
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

stamp_ok() { echo "ok" > "$1"; }
is_ok() { [ -f "$1" ] && grep -q "^ok$" "$1" 2>/dev/null; }

port_open() {
  local port="$1"
  if have_cmd ss; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
  else
    return 1
  fi
}

echo "[1/7] System packages"
if ! is_ok "$STATE_DIR/apt.ok"; then
  apt-get update
  apt-get install -y --no-install-recommends \
    git git-lfs wget curl unzip \
    python3 python3-venv python3-pip \
    ffmpeg libgl1 libglib2.0-0 \
    htop nano tmux ca-certificates \
    iproute2 coreutils gawk
  stamp_ok "$STATE_DIR/apt.ok"
else
  echo "System packages already installed (state: $STATE_DIR/apt.ok)"
fi

git lfs install || true

cd "$WORKDIR"

echo "[2/7] ComfyUI repo"
if [ ! -d "$COMFY_DIR/.git" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "ComfyUI already exists: $COMFY_DIR"
fi

echo "[3/7] Python venv + requirements"
cd "$COMFY_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip wheel setuptools

# Pytorch (CUDA 12.8 wheels). If it fails, fallback to default index.
if ! python -c "import torch, torchvision, torchaudio" >/dev/null 2>&1; then
  if ! python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128; then
    echo "WARN: CUDA wheels install failed, trying default pip index..."
    python -m pip install torch torchvision torchaudio
  fi
else
  echo "Torch already installed in venv"
fi

REQ_SHA="$(sha_file "$COMFY_DIR/requirements.txt")"
REQ_STAMP="$STATE_DIR/comfy_requirements.sha"
if [ -n "$REQ_SHA" ] && [ -f "$REQ_STAMP" ] && grep -q "^$REQ_SHA$" "$REQ_STAMP"; then
  echo "ComfyUI requirements unchanged; skipping pip install -r requirements.txt"
else
  python -m pip install -r requirements.txt
  echo "$REQ_SHA" > "$REQ_STAMP"
fi

echo "[4/7] Custom nodes"
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
      echo "Custom node $d requirements unchanged; skipping"
    else
      python -m pip install -r "$d/requirements.txt"
      echo "$NODE_SHA" > "$NODE_STAMP"
    fi
  fi
done

echo "[5/7] Models (download if missing)"
mkdir -p "$COMFY_DIR/models/diffusion_models" \
         "$COMFY_DIR/models/text_encoders" \
         "$COMFY_DIR/models/vae"

# NOTE: diffusion model download is commented by default (large).
# wget -c -O "$COMFY_DIR/models/diffusion_models/flux-2-klein-9b.safetensors" \
#  "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"

if [ ! -f "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors" ]; then
  wget -c -O "$COMFY_DIR/models/text_encoders/qwen_3_8b.safetensors" \
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"
fi

if [ ! -f "$COMFY_DIR/models/vae/flux2-vae.safetensors" ]; then
  wget -c -O "$COMFY_DIR/models/vae/flux2-vae.safetensors" \
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
fi

echo "[6/7] JupyterLab"
if ! python -c "import jupyterlab, notebook, ipykernel" >/dev/null 2>&1; then
  python -m pip install jupyterlab notebook ipykernel
else
  echo "Jupyter packages already installed in venv"
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

echo "[7/7] Autostart (Jupyter first, then ComfyUI)"
mkdir -p "$LOG_DIR"

# Start JupyterLab first
if port_open 8888; then
  echo "JupyterLab already listening on port 8888; skipping start"
else
  nohup bash -lc "
    source \"$VENV_DIR/bin/activate\"
    jupyter lab --config=/root/.jupyter/jupyter_lab_config.py
  " > "$LOG_DIR/jupyter.log" 2>&1 &
fi

# Give Jupyter a moment to bind the port (optional)
sleep 2

# Start ComfyUI after Jupyter
if port_open 8188; then
  echo "ComfyUI already listening on port 8188; skipping start"
else
  nohup bash -lc "
    cd \"$COMFY_DIR\"
    source \"$VENV_DIR/bin/activate\"
    python main.py --listen 0.0.0.0 --port 8188 --disable-auto-launch --enable-cors-header
  " > "$LOG_DIR/comfyui.log" 2>&1 &
fi

echo "--------------------------------------"
echo "ComfyUI:    http://SERVER_IP:8188"
echo "JupyterLab: http://SERVER_IP:8888"
echo "Logs:       $LOG_DIR"
echo "--------------------------------------"

