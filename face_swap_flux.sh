#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKDIR/ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFY_DIR/venv}"
LOG_DIR="${LOG_DIR:-$WORKDIR/logs}"

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] System packages"
apt-get update
apt-get install -y --no-install-recommends \
  git git-lfs wget curl unzip \
  python3 python3-venv python3-pip \
  ffmpeg libgl1 libglib2.0-0 \
  htop nano tmux ca-certificates

git lfs install || true

mkdir -p "$WORKDIR"
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
if ! python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128; then
  echo "WARN: CUDA wheels install failed, trying default pip index..."
  python -m pip install torch torchvision torchaudio
fi

python -m pip install -r requirements.txt

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
    python -m pip install -r "$d/requirements.txt"
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
python -m pip install jupyterlab notebook ipykernel

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
nohup bash -lc "
  source \"$VENV_DIR/bin/activate\"
  jupyter lab --config=/root/.jupyter/jupyter_lab_config.py
" > "$LOG_DIR/jupyter.log" 2>&1 &

# Give Jupyter a moment to bind the port (optional)
sleep 2

# Start ComfyUI after Jupyter
nohup bash -lc "
  cd \"$COMFY_DIR\"
  source \"$VENV_DIR/bin/activate\"
  python main.py --listen 0.0.0.0 --port 8188 --disable-auto-launch --enable-cors-header
" > "$LOG_DIR/comfyui.log" 2>&1 &

echo "--------------------------------------"
echo "ComfyUI:    http://SERVER_IP:8188"
echo "JupyterLab: http://SERVER_IP:8888"
echo "Logs:       $LOG_DIR"
echo "--------------------------------------"

