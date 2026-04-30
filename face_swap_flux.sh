
#!/usr/bin/env bash
set -e

cd /workspace

apt-get update
apt-get install -y \
git git-lfs wget curl unzip \
python3 python3-venv python3-pip \
ffmpeg libgl1 libglib2.0-0 \
htop nano tmux

git lfs install

# -------------------------
# COMFYUI
# -------------------------

if [ ! -d /workspace/ComfyUI ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git
fi

cd /workspace/ComfyUI

python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip wheel setuptools

pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt

# -------------------------
# CUSTOM NODES
# -------------------------

mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes

if [ ! -d rgthree-comfy ]; then
  git clone https://github.com/rgthree/rgthree-comfy.git
fi

if [ ! -d ComfyUI-Easy-Use ]; then
  git clone https://github.com/yolain/ComfyUI-Easy-Use.git
fi

for d in rgthree-comfy ComfyUI-Easy-Use; do
  if [ -f "$d/requirements.txt" ]; then
    pip install -r "$d/requirements.txt"
  fi
done

# -------------------------
# MODELS
# -------------------------

mkdir -p /workspace/ComfyUI/models/diffusion_models
mkdir -p /workspace/ComfyUI/models/text_encoders
mkdir -p /workspace/ComfyUI/models/vae

# wget -c -O /workspace/ComfyUI/models/diffusion_models/flux-2-klein-9b.safetensors \
# "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors"

wget -c -O /workspace/ComfyUI/models/text_encoders/qwen_3_8b.safetensors \
"https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"

wget -c -O /workspace/ComfyUI/models/vae/flux2-vae.safetensors \
"https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"

# -------------------------
# JUPYTER LAB
# -------------------------

pip install jupyterlab notebook ipykernel

mkdir -p /root/.jupyter

cat > /root/.jupyter/jupyter_lab_config.py <<EOF
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.disable_check_xsrf = True
EOF

# -------------------------
# AUTOSTART
# -------------------------

mkdir -p /workspace/logs

# Start JupyterLab
nohup bash -c "
source /workspace/ComfyUI/venv/bin/activate
jupyter lab --config=/root/.jupyter/jupyter_lab_config.py
" > /workspace/logs/jupyter.log 2>&1 &

# Start ComfyUI
nohup bash -c "
cd /workspace/ComfyUI
source venv/bin/activate
python main.py --listen 0.0.0.0 --port 8188 --disable-auto-launch --enable-cors-header
" > /workspace/logs/comfyui.log 2>&1 &

echo "--------------------------------------"
echo "ComfyUI:   http://SERVER_IP:8188"
echo "JupyterLab: http://SERVER_IP:8888"
echo "--------------------------------------"
