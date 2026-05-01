#!/bin/bash
#
# Runpod slim: SSH + export env + FileBrowser + Jupyter + ComfyUI (как у вас)
# Дополнительно: extra custom nodes (rgthree, Easy-Use) + СКАЧИВАНИЕ моделей перед стартом ComfyUI.
#
# Модели (install_extra_nodes_and_models): если файла нет — hub, иначе wget; HF_TOKEN для gated:
#   $COMFYUI_DIR/models/text_encoders/qwen_3_8b.safetensors
#   $COMFYUI_DIR/models/vae/flux2-vae.safetensors
#
# HF: задайте HF_TOKEN (= {{ RUNPOD_SECRET_HF_TOKEN }}) или RUNPOD_SECRET_HF_TOKEN;
# переменная попадает в export_env_vars через расширенный паттерн.
#
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
OLD_VENV_DIR="$COMFYUI_DIR/.venv"
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
EXTRA_STATE_DIR="$COMFYUI_DIR/.extra_nodes_models_state"

# ---------------------------------------------------------------------------- #
#                     Hugging Face + models / extra nodes                        #
# ---------------------------------------------------------------------------- #

normalize_hf_token() {
  if [[ -z "${HF_TOKEN:-}" && -n "${RUNPOD_SECRET_HF_TOKEN:-}" ]]; then
    export HF_TOKEN="${RUNPOD_SECRET_HF_TOKEN}"
  fi
  if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    export HF_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
  fi
  if [[ -z "${HF_TOKEN:-}" && -n "${HUGGINGFACEHUB_API_TOKEN:-}" ]]; then
    export HF_TOKEN="${HUGGINGFACEHUB_API_TOKEN}"
  fi
  [[ -n "${HF_TOKEN:-}" ]] && export HF_TOKEN
}

sha_file() {
  local f="$1"
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

need_cmd_extra() {
  command -v "$1" >/dev/null 2>&1
}

hf_header_args() {
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
  python -m pip install -q "huggingface_hub[cli]>=0.24.0"
}

hf_download_file() {
  local repo_id="$1"
  local filename="$2"
  local dest_file="$3"

  mkdir -p "$(dirname "$dest_file")"
  local tmp="${dest_file}.part"
  rm -f "$tmp"

  python <<PY
from huggingface_hub import hf_hub_download
import os
import shutil

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

download_model_file_extra() {
  local repo_id="$1" filename="$2" dest_file="$3" url="${4:-}"
  if [[ -s "$dest_file" ]]; then
    echo "[models] уже есть: $dest_file"
    return 0
  fi
  echo "[models] скачиваю → $dest_file ($repo_id)"
  if ensure_huggingface_hub && hf_download_file "$repo_id" "$filename" "$dest_file"; then
    return 0
  fi
  if [[ -z "$url" ]]; then
    echo "ERROR: huggingface_hub download failed for: $dest_file"
    return 1
  fi
  need_cmd_extra wget || {
    echo "ERROR: wget not found for HF fallback"
    return 1
  }
  echo "WARN: HF hub не сработал, wget: $dest_file"
  local WGET_HF_ARGS
  WGET_HF_ARGS="$(hf_header_args)"
  wget -c $WGET_HF_ARGS -O "${dest_file}.part" "$url"
  mv -f "${dest_file}.part" "$dest_file"
}

# Вызывается после source venv: python === $VENV_DIR/bin/python
install_extra_nodes_and_models() {
  need_cmd_extra git || {
    echo "ERROR: git missing; cannot clone extra nodes"
    return 1
  }

  mkdir -p "$EXTRA_STATE_DIR"
  mkdir -p "$COMFYUI_DIR/custom_nodes"
  cd "$COMFYUI_DIR/custom_nodes"

  if [[ ! -d rgthree-comfy/.git ]]; then
    git clone --depth 1 https://github.com/rgthree/rgthree-comfy.git
  fi
  if [[ ! -d ComfyUI-Easy-Use/.git ]]; then
    git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git
  fi

  for d in rgthree-comfy ComfyUI-Easy-Use; do
    if [[ -f "$d/requirements.txt" ]]; then
      NODE_SHA="$(sha_file "$d/requirements.txt")"
      NODE_STAMP="$EXTRA_STATE_DIR/node_${d}_requirements.sha"
      if [[ -n "$NODE_SHA" && -f "$NODE_STAMP" ]] && grep -q "^${NODE_SHA}$" "$NODE_STAMP"; then
        echo "[extra nodes] $d requirements unchanged — skip pip"
      else
        echo "[extra nodes] pip install -r $d/requirements.txt"
        python -m pip install -q -r "$d/requirements.txt"
        echo "$NODE_SHA" > "$NODE_STAMP"
      fi
    fi
  done

  mkdir -p "$COMFYUI_DIR/models/diffusion_models" \
           "$COMFYUI_DIR/models/text_encoders" \
           "$COMFYUI_DIR/models/vae"

  echo "[models] установка снимков (HF hub → при ошибке wget; задайте HF_TOKEN при необходимости)"
  download_model_file_extra \
    "Comfy-Org/vae-text-encorder-for-flux-klein-9b" \
    "split_files/text_encoders/qwen_3_8b.safetensors" \
    "$COMFYUI_DIR/models/text_encoders/qwen_3_8b.safetensors" \
    "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b.safetensors"

  download_model_file_extra \
    "Comfy-Org/flux2-dev" \
    "split_files/vae/flux2-vae.safetensors" \
    "$COMFYUI_DIR/models/vae/flux2-vae.safetensors" \
    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"

  cd "$COMFYUI_DIR"
  echo "[extra nodes + models] done"
}

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

setup_ssh() {
    mkdir -p ~/.ssh
    
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

export_env_vars() {
    echo "Exporting environment variables..."
    
    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"
    
    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true
    
    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"
    : > /etc/rp_environment

    normalize_hf_token
    
    printenv | grep -E '^RUNPOD_|^RUNPOD_SECRET_|^HF_TOKEN|^HUGGING_FACE_HUB|^HUGGINGFACEHUB_API|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^JUPYTER_' | while read -r line; do
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done
    
    grep -q 'source /etc/rp_environment' ~/.bashrc || echo 'source /etc/rp_environment' >> ~/.bashrc
    grep -q 'source /etc/rp_environment' /etc/bash.bashrc || echo 'source /etc/rp_environment' >> /etc/bash.bashrc
    
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

setup_ssh

# Ensure HF_* exist before exporting (secrets may only set RUNPOD_SECRET_* )
normalize_hf_token
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

# Start FileBrowser
echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

# Create default comfyui_args.txt if it doesn't exist
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Migrate old CUDA 12.4 venv to cu128
if [ -d "$OLD_VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
    NODE_COUNT=$(find "$COMFYUI_DIR/custom_nodes" -maxdepth 2 -name "requirements.txt" 2>/dev/null | wc -l)
    echo "============================================="
    echo "  CUDA 12.4 -> 12.8 migration"
    echo "  Reinstalling deps for $NODE_COUNT custom nodes"
    echo "  This may take several minutes"
    echo "============================================="
    mv "$OLD_VENV_DIR" "${OLD_VENV_DIR}.bak"
    cd "$COMFYUI_DIR"
    python3.12 -m venv --system-site-packages "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    python -m ensurepip
    # Skip nodes baked into the image — their deps are in system site-packages
    BAKED_NODES="ComfyUI-Manager ComfyUI-KJNodes Civicomfy ComfyUI-RunpodDirect"
    CURRENT=0
    INSTALLED=0
    for req in "$COMFYUI_DIR"/custom_nodes/*/requirements.txt; do
        if [ -f "$req" ]; then
            NODE_NAME=$(basename "$(dirname "$req")")
            case " $BAKED_NODES " in
                *" $NODE_NAME "*) continue ;;
            esac
            CURRENT=$((CURRENT + 1))
            echo "[$CURRENT] $NODE_NAME"
            pip install -r "$req" 2>&1 | grep -E "^(Successfully|ERROR)" || true
            INSTALLED=$((INSTALLED + 1))
        fi
    done
    echo "Upgrading ComfyUI requirements..."
    pip install --upgrade -r "$COMFYUI_DIR/requirements.txt" 2>&1 | grep -E "^(Successfully|ERROR)" || true
    echo "Migration complete — $INSTALLED user nodes processed (${NODE_COUNT} total, baked nodes skipped)"
    echo "Old venv backed up at ${OLD_VENV_DIR}.bak — delete it to free space:"
    echo "  rm -rf ${OLD_VENV_DIR}.bak"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."

    # Copy baked ComfyUI from image (no git, no network)
    if [ ! -d "$COMFYUI_DIR" ]; then
        cp -r /opt/comfyui-baked "$COMFYUI_DIR"
        echo "ComfyUI copied to workspace"
    fi

    # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        python -m ensurepip

        echo "Base packages (torch, numpy, etc.) available from system site-packages"
        echo "ComfyUI ready — all dependencies pre-installed in image"
    fi
else
    # Just activate the existing venv
    source "$VENV_DIR/bin/activate"
    echo "Using existing ComfyUI installation"
fi

# Warm up pip so ComfyUI-Manager's 5s timeout check doesn't fail on cold start
python -m pip --version > /dev/null 2>&1

# Extra clones + pip for rgthree/Easy-Use + Flux-related models (after venv is active)
install_extra_nodes_and_models

normalize_hf_token

cd "$COMFYUI_DIR"
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
python main.py $FIXED_ARGS &
COMFY_PID=$!
trap "kill $COMFY_PID 2>/dev/null" SIGTERM SIGINT
wait $COMFY_PID || true

echo "============================================="
echo "  ComfyUI crashed — check the logs above."
echo "  SSH and JupyterLab are still available."
echo "  To restart after fixing:"
echo "    cd $COMFYUI_DIR && source .venv-cu128/bin/activate"
echo "    python main.py $FIXED_ARGS"
echo "============================================="

sleep infinity
