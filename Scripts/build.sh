#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

WORKDIR=""

cleanup() { [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

build_model() {
  local MODEL_NAME="$1" OUTPUT_NAME="$2"

  local MODEL_DIR="$PROJECT_DIR/models/$MODEL_NAME"
  [ ! -d "$MODEL_DIR" ] && echo "Error: model folder '$MODEL_NAME' not found" && exit 1
  [ ! -f "$PROJECT_DIR/AppRun.template" ] && echo "Error: AppRun.template not found" && exit 1

  echo "Packaging: $MODEL_NAME -> $OUTPUT_NAME"

  local MODEL_FILES=() MMPROJ_FILES=()
  for f in "$MODEL_DIR"/*.gguf; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"
    if echo "$bn" | grep -qi "mmproj"; then
      MMPROJ_FILES+=("$f")
    else
      MODEL_FILES+=("$f")
    fi
  done
  [ ${#MODEL_FILES[@]} -eq 0 ] && echo "Error: no .gguf files in $MODEL_DIR" && exit 1

  # Ask user which engine to use
  local IS_WHISPER="n"
  if [ -t 0 ]; then
    read -p "Is this a whisper model? [y/N]: " IS_WHISPER
  fi

  local ENGINE_DIR SERVER_BIN CLI_BIN
  if [[ "$IS_WHISPER" == [yY]* ]]; then
    ENGINE_DIR="$PROJECT_DIR/Engines/whisper.cpp"
    SERVER_BIN="whisper-server"
    CLI_BIN="whisper-cli"
  else
    ENGINE_DIR="$PROJECT_DIR/Engines/llama.cpp"
    SERVER_BIN="llama-server"
    CLI_BIN="llama-cli"
  fi

  if [ ! -f "$ENGINE_DIR/$SERVER_BIN" ]; then
    echo "Engine not found. Installing..."
    bash "$SCRIPT_DIR/install-engine.sh"
  fi

  WORKDIR="$(mktemp -d)"

  mkdir -p "$WORKDIR"/usr/{bin,lib}
  mkdir -p "$WORKDIR/usr/share/models"

  cp "$ENGINE_DIR/$SERVER_BIN" "$WORKDIR/usr/bin/"
  if [[ "$IS_WHISPER" == [yY]* ]]; then
    cp "$ENGINE_DIR/whisper-cli" "$WORKDIR/usr/bin/" 2>/dev/null || true
  else
    cp "$ENGINE_DIR/llama-cli" "$WORKDIR/usr/bin/"
  fi
  for f in "$ENGINE_DIR"/*.so*; do
    [ -f "$f" ] && cp -L "$f" "$WORKDIR/usr/bin/"
  done

  cp -L "${MODEL_FILES[0]}" "$WORKDIR/usr/share/models/model.gguf"
  if [ ${#MMPROJ_FILES[@]} -gt 0 ]; then
    cp -L "${MMPROJ_FILES[0]}" "$WORKDIR/usr/share/models/mmproj.gguf"
  fi

  local MODEL_SIZE
  MODEL_SIZE=$(du -hL "${MODEL_FILES[0]}" | cut -f1)
  local HAS_VULKAN="no"
  [ -f "$ENGINE_DIR/libggml-vulkan.so" ] && HAS_VULKAN="yes"

  echo ""
  echo "--- Default parameters (can be overridden at runtime) ---"
  if [[ "$IS_WHISPER" == [yY]* ]]; then
    read -p "Port [9977]: " PORT; PORT="${PORT:-9977}"
  else
    read -p "Context size [0]: " CTX_SIZE; CTX_SIZE="${CTX_SIZE:-0}"
    read -p "Batch size [2048]: " BATCH_SIZE; BATCH_SIZE="${BATCH_SIZE:-2048}"
    local SPEC_TYPES="none, draft-simple, draft-eagle3, draft-mtp, ngram-simple, ngram-map-k, ngram-map-k4v, ngram-mod, ngram-cache"
    read -p "Speculative decoding type [$SPEC_TYPES] [none]: " SPEC_TYPE; SPEC_TYPE="${SPEC_TYPE:-none}"
    local DEFAULT_NGL="0"
    [ "$HAS_VULKAN" = "yes" ] && DEFAULT_NGL="99"
    read -p "GPU layers (Vulkan: ${HAS_VULKAN}) [$DEFAULT_NGL]: " N_GPU_LAYERS; N_GPU_LAYERS="${N_GPU_LAYERS:-$DEFAULT_NGL}"
    read -p "Model alias [$OUTPUT_NAME]: " MODEL_ALIAS; MODEL_ALIAS="${MODEL_ALIAS:-$OUTPUT_NAME}"
    local DEFAULT_THR="4"
    read -p "CPU threads [$DEFAULT_THR]: " THREADS; THREADS="${THREADS:-$DEFAULT_THR}"
  fi
  echo ""

  sed -e "s/@NAME@/$OUTPUT_NAME/g" \
      -e "s/@MODEL_SIZE@/$MODEL_SIZE/g" \
      -e "s/@HAS_VULKAN@/$HAS_VULKAN/g" \
      -e "s/@CTX_SIZE@/${CTX_SIZE:-0}/g" \
      -e "s/@BATCH_SIZE@/${BATCH_SIZE:-2048}/g" \
      -e "s/@SPEC_TYPE@/${SPEC_TYPE:-none}/g" \
      -e "s/@N_GPU_LAYERS@/${N_GPU_LAYERS:-0}/g" \
      -e "s/@MODEL_ALIAS@/${MODEL_ALIAS:-$OUTPUT_NAME}/g" \
      -e "s/@THREADS@/${THREADS:-4}/g" \
      -e "s/@SERVER_BIN@/$SERVER_BIN/g" \
      -e "s/@CLI_BIN@/$CLI_BIN/g" \
      -e "s/@IS_WHISPER@/$([[ "$IS_WHISPER" == [yY]* ]] && echo yes || echo no)/g" \
      "$PROJECT_DIR/AppRun.template" > "$WORKDIR/AppRun"
  chmod +x "$WORKDIR/AppRun"

  cat > "$WORKDIR/$OUTPUT_NAME.desktop" << EOF
[Desktop Entry]
Name=$OUTPUT_NAME
Exec=$SERVER_BIN
Icon=$OUTPUT_NAME
Type=Application
Categories=Utility;
Terminal=true
EOF

  # placeholder icon (1x1 blue pixel PNG)
  printf '\x89PNG\r\n\x1a\n' > "$WORKDIR/$OUTPUT_NAME.png"
  printf '\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde' >> "$WORKDIR/$OUTPUT_NAME.png"
  printf '\x00\x00\x00\x0cIDAT\x08\xd7c\xf8\x0f\x00\x00\x00\x00\xff\xff\x03\x00\x00\x04\x00\x01\x0c\x0c\x92' >> "$WORKDIR/$OUTPUT_NAME.png"
  printf '\x00\x00\x00\x00IEND\xaeB`\x82' >> "$WORKDIR/$OUTPUT_NAME.png"

  mkdir -p "$PROJECT_DIR/dist"
  appimagetool "$WORKDIR" "$PROJECT_DIR/dist/${OUTPUT_NAME}-x86_64.AppImage"

  echo "Done: $PROJECT_DIR/dist/${OUTPUT_NAME}-x86_64.AppImage ($MODEL_SIZE)"
}

source "$SCRIPT_DIR/huggingface.sh"

# --- Collect models ---
MODELS=()
for d in "$PROJECT_DIR/models/"*/; do
  name="$(basename "$d")"
  gfiles=("$d"/*.gguf)
  [ ${#gfiles[@]} -gt 0 ] && [ -f "${gfiles[0]}" ] || continue
  MODELS+=("$name")
done

# --- Parse args ---
if [ $# -ge 1 ]; then
  case "$1" in
    -h|--help)
      echo "Usage: $0 [model-folder] [-n name]"; echo "       $0 (interactive)"; echo "       $0 (-d|--download)"; exit 0 ;;
    -i|--interactive) ;;
    -d|--download) download_gguf; exit 0 ;;
    *)
      MODEL_NAME="$1"
      OUTPUT_NAME="$MODEL_NAME"
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) OUTPUT_NAME="$2"; shift 2 ;;
          *) echo "Unknown: $1"; exit 1 ;;
        esac
      done
      build_model "$MODEL_NAME" "$OUTPUT_NAME"
      exit 0 ;;
  esac
fi

# --- Interactive ---
if [ ${#MODELS[@]} -eq 0 ]; then
  echo "No model folders found."
  download_gguf
  exit 0
fi

echo "Select a model to package:"
select m in "Download from Hugging Face" "${MODELS[@]}" "Cancel"; do
  case "$m" in
    "Cancel") echo "Aborted."; exit 0 ;;
    "Download from Hugging Face") download_gguf; break ;;
    "") echo "Invalid selection" ;;
    *) build_model "$m" "$m"; break ;;
  esac
done
