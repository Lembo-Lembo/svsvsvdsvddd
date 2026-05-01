#!/usr/bin/env bash
# Только кастом-ноды + модели. Без apt, без venv/torch, без Jupyter, без автозапуска ComfyUI.
# Требуется уже установленный ComfyUI и рабочие git + python3 (как в образе Runpod).
#
# Hugging Face:
#   HF_TOKEN = {{ RUNPOD_SECRET_HF_TOKEN }}
#   Также пробрасываются: RUNPOD_SECRET_HF_TOKEN, HUGGING_FACE_HUB_TOKEN, HUGGINGFACEHUB_API_TOKEN → HF_TOKEN
#
# Переменные:
#   COMFY_DIR   — корень ComfyUI (по умолчанию $WORKDIR/ComfyUI). Runpod slim часто так:
#               COMFY_DIR=/workspace/runpod-slim/ComfyUI
#   WORKDIR     — по умолчанию /workspace
#   PYTHON      — для hf_hub / pip зависимостей нод (по умолчанию python3; на slim укажите .venv/bin/python)
#   STATE_DIR   — кеш sha по requirements нод ($COMFY_DIR/.setup_nodes_state)

set -euo pipefail

WORKDIR="${WORKDIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$WORKDIR/ComfyUI}"
PYTHON="${PYTHON:-python3}"
STATE_DIR="${STATE_DIR:-$COMFY_DIR/.setup_nodes_state}"

sha_file() {
  local f="$1"
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

hf_header_args() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "--header=Authorization: Bearer ${HF_TOKEN}"
  else
    echo ""
  fi
}

ensure_huggingface_hub() {
  if "$PYTHON" -c "import huggingface_hub" >/dev/null 2>&1; then
    return 0
  fi
  "$PYTHON" -m pip install -q "huggingface_hub[cli]>=0.24.0"
}

hf_download_file() {
  local repo_id="$1"
  local filename="$2"
  local dest_file="$3"

  mkdir -p "$(dirname "$dest_file")"
  local tmp="${dest_file}.part"
  rm -f "$tmp"

  "$PYTHON" - <<PY
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
  need_cmd wget || {
    echo "ERROR: wget not found for fallback URL"
    return 1
  }
  echo "WARN: falling back to wget for $dest_file"
  local WGET_HF_ARGS
  WGET_HF_ARGS="$(hf_header_args)"
  wget -q -c $WGET_HF_ARGS -O "${dest_file}.part" "$url"
  mv -f "${dest_file}.part" "$dest_file"
}

# ---- HF_TOKEN ----
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

# ---- Sanity ----
need_cmd git || {
  echo "ERROR: git is required for custom nodes."
  exit 1
}
need_cmd "$PYTHON" || {
  echo "ERROR: $PYTHON not found (models + optional pip deps)."
  exit 1
}

if [[ ! -d "$COMFY_DIR" ]]; then
  echo "ERROR: COMFY_DIR does not exist: $COMFY_DIR"
  exit 2
fi

mkdir -p "$STATE_DIR"

echo "[1/2] Custom nodes"
mkdir -p "$COMFY_DIR/custom_nodes"
cd "$COMFY_DIR/custom_nodes"

if [[ ! -d rgthree-comfy/.git ]]; then
  git clone --depth 1 https://github.com/rgthree/rgthree-comfy.git
fi
if [[ ! -d ComfyUI-Easy-Use/.git ]]; then
  git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git
fi

for d in rgthree-comfy ComfyUI-Easy-Use; do
  if [[ -f "$d/requirements.txt" ]]; then
    NODE_SHA="$(sha_file "$d/requirements.txt")"
    NODE_STAMP="$STATE_DIR/node_${d}_requirements.sha"
    if [[ -n "$NODE_SHA" && -f "$NODE_STAMP" ]] && grep -q "^${NODE_SHA}$" "$NODE_STAMP"; then
      echo "Node $d requirements unchanged, skip pip"
    else
      "$PYTHON" -m pip install -q -r "$d/requirements.txt"
      echo "$NODE_SHA" > "$NODE_STAMP"
    fi
  fi
done

echo "[2/2] Models (huggingface_hub + HF_TOKEN; wget fallback)"
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

echo "Done. COMFY_DIR=$COMFY_DIR"
