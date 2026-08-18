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

  local PARAKEET=0
  [ -n "$(find "$MODEL_DIR" -maxdepth 1 -name '*.onnx' -print -quit)" ] && PARAKEET=1

  local MODEL_FILES=() MMPROJ_FILES=()
  for f in "$MODEL_DIR"/*.gguf "$MODEL_DIR"/ggml-*.bin; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"
    if echo "$bn" | grep -qi "mmproj"; then
      MMPROJ_FILES+=("$f")
    else
      MODEL_FILES+=("$f")
    fi
  done
  if [ "$PARAKEET" -eq 0 ]; then
    [ ${#MODEL_FILES[@]} -eq 0 ] && echo "Error: no .gguf or .onnx files in $MODEL_DIR" && exit 1
  fi

  # Ask user which engine to use
  local IS_WHISPER="n"
  local ENGINE_HINT=""
  [ -f "$MODEL_DIR/.engine" ] && ENGINE_HINT="$(cat "$MODEL_DIR/.engine")"
  if [ "$PARAKEET" -eq 0 ]; then
    case "$ENGINE_HINT" in
      whisper) IS_WHISPER="y" ;;
      llama|gguf) IS_WHISPER="n" ;;
      *)
        # No hint: ask only when interactive; otherwise default to llama
        if [ -t 0 ]; then
          read -p "Is this a whisper model? [y/N]: " IS_WHISPER
        fi
        ;;
    esac
  fi

  local ENGINE_DIR SERVER_BIN CLI_BIN
  if [[ "$IS_WHISPER" == [yY]* ]]; then
    ENGINE_DIR="$PROJECT_DIR/Engines/whisper.cpp"
    SERVER_BIN="whisper-server"
    CLI_BIN="whisper-cli"
  elif [ "$PARAKEET" -eq 1 ]; then
    ENGINE_DIR="$PROJECT_DIR/Engines/parakeet"
    SERVER_BIN="parakeet"
    CLI_BIN="parakeet"
  else
    ENGINE_DIR="$PROJECT_DIR/Engines/llama.cpp"
    SERVER_BIN="llama-server"
    CLI_BIN="llama-cli"
  fi

  if [ ! -f "$ENGINE_DIR/$SERVER_BIN" ]; then
    echo "Engine not found. Installing..."
    local ENGINE_NAME="llama"
    [[ "$IS_WHISPER" == [yY]* ]] && ENGINE_NAME="whisper"
    [ "$PARAKEET" -eq 1 ] && ENGINE_NAME="parakeet"
    bash "$SCRIPT_DIR/install-engine.sh" "$ENGINE_NAME"
  fi

  local HAS_VULKAN="no"
  [ -f "$ENGINE_DIR/libggml-vulkan.so" ] && HAS_VULKAN="yes"

  local PRECISION="int8"   # parakeet: rewritten below; irrelevant for other engines

  echo ""
  echo "--- Default parameters (can be overridden at runtime) ---"
  if [ "$PARAKEET" -eq 1 ]; then
    read -p "Port [9977]: " PORT; PORT="${PORT:-9977}"
    read -p "GPU provider (cpu/cuda) [cpu]: " GPU; GPU="${GPU:-cpu}"
    if [ "$GPU" = "cuda" ]; then
      read -p "Workers (each ~3GB VRAM on GPU) [1]: " WORKERS; WORKERS="${WORKERS:-1}"
    else
      read -p "Workers (each ~670MB RAM) [2]: " WORKERS; WORKERS="${WORKERS:-2}"
    fi
    # Precision selector: int8 = compact/fast, fp32 = full accuracy (esp. on GPU).
    # Default is auto-detected from whatever model files are already in the folder.
    local HAVE_INT8=0 HAVE_FP32=0
    [ -f "$MODEL_DIR/encoder-model.int8.onnx" ] && HAVE_INT8=1
    [ -f "$MODEL_DIR/encoder-model.onnx" ] && [ -f "$MODEL_DIR/encoder-model.onnx.data" ] && HAVE_FP32=1
    local PREC_DEFAULT="int8"
    [ "$HAVE_FP32" -eq 1 ] && [ "$HAVE_INT8" -eq 0 ] && PREC_DEFAULT="fp32"
    read -p "Model precision (int8/fp32) [$PREC_DEFAULT]: " PRECISION
    PRECISION="${PRECISION:-$PREC_DEFAULT}"
    case "${PRECISION,,}" in
      int8) PRECISION="int8" ;;
      fp32) PRECISION="fp32" ;;
      *) echo "Error: precision must be 'int8' or 'fp32' (got: $PRECISION)." >&2; exit 1 ;;
    esac
    if [ "$PRECISION" = "int8" ] && [ "$HAVE_INT8" -eq 0 ]; then
      echo "Error: no int8 model files in $MODEL_DIR" >&2
      echo "Run: Scripts/download-parakeet-models.sh  and answer 'int8'" >&2
      exit 1
    fi
    if [ "$PRECISION" = "fp32" ] && [ "$HAVE_FP32" -eq 0 ]; then
      echo "Error: no fp32 model files (encoder-model.onnx/.data, decoder_joint-model.onnx) in $MODEL_DIR" >&2
      echo "Run: Scripts/download-parakeet-models.sh  and answer 'fp32'" >&2
      exit 1
    fi
    if [ "$PRECISION" = "fp32" ]; then
      if [ "$GPU" = "cuda" ]; then
        echo "Note: fp32 needs ~3GB VRAM per worker on GPU; keep --workers low."
      else
        echo "Note: fp32 needs ~6GB RAM per worker on CPU."
      fi
    fi
  elif [[ "$IS_WHISPER" == [yY]* ]]; then
    read -p "Port [9977]: " PORT; PORT="${PORT:-9977}"
    read -p "CPU threads [12]: " THREADS; THREADS="${THREADS:-12}"
    read -p "Best of [3]: " BEST_OF; BEST_OF="${BEST_OF:-3}"
    read -p "Stream mode by default (real-time mic) [y/N]: " STREAM_MODE
    if [[ "$STREAM_MODE" == [yY]* ]]; then
      read -p "  Step (ms, 0=VAD sliding window) [0]: " STEP; STEP="${STEP:-0}"
      read -p "  Length (ms) [30000]: " LENGTH; LENGTH="${LENGTH:-30000}"
      read -p "  VAD threshold [0.6]: " VTH; VTH="${VTH:-0.6}"
    fi
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

  WORKDIR="$(mktemp -d)"

  mkdir -p "$WORKDIR"/usr/{bin,lib}
  mkdir -p "$WORKDIR/usr/share/models"

  cp "$ENGINE_DIR/$SERVER_BIN" "$WORKDIR/usr/bin/"
  if [[ "$IS_WHISPER" == [yY]* ]]; then
    cp "$ENGINE_DIR/whisper-cli" "$WORKDIR/usr/bin/" 2>/dev/null || true
    cp "$ENGINE_DIR/whisper-stream" "$WORKDIR/usr/bin/" 2>/dev/null || true
  elif [ "$PARAKEET" -eq 1 ]; then
    :
  else
    cp "$ENGINE_DIR/llama-cli" "$WORKDIR/usr/bin/"
  fi

  # Copy engine shared libraries (parakeet: CPU or CUDA build as chosen above)
  if [ "$PARAKEET" -eq 1 ]; then
    if [ "$GPU" = "cuda" ]; then
      local CUDA_LIBS_OK=0
      [ -f "$ENGINE_DIR/libonnxruntime-gpu.so" ] && \
        [ -n "$(find "$ENGINE_DIR/cuda" -maxdepth 1 -name '*.so*' -print -quit 2>/dev/null)" ] && \
        CUDA_LIBS_OK=1
      if [ "$CUDA_LIBS_OK" -eq 1 ]; then
        local ORTVER
        ORTVER=$(basename "$(readlink -f "$ENGINE_DIR/libonnxruntime-gpu.so")" | sed 's/.*\.so\.//')
        cp -a "$ENGINE_DIR/libonnxruntime-gpu.so.${ORTVER}" "$WORKDIR/usr/bin/libonnxruntime.so.${ORTVER}"
        ln -sf "libonnxruntime.so.${ORTVER}" "$WORKDIR/usr/bin/libonnxruntime.so.1"
        ln -sf "libonnxruntime.so.1" "$WORKDIR/usr/bin/libonnxruntime.so"
        for f in "$ENGINE_DIR"/cuda/*.so*; do
          [ -f "$f" ] && cp -a "$f" "$WORKDIR/usr/lib/"
        done
        # ORT >= 1.17 CUDA EP split provider libs (dlopened by the main lib)
        for f in "$ENGINE_DIR"/libonnxruntime_providers_*.so; do
          [ -f "$f" ] && cp -a "$f" "$WORKDIR/usr/bin/"
        done
      else
        echo "Error: CUDA support requested but CUDA runtime libraries are not installed."
        echo "Run: Scripts/install-engine.sh --force parakeet  and answer 'y' to CUDA GPU support."
        echo "Then rebuild with GPU provider 'cuda'."
        exit 1
      fi
    else
      for f in "$ENGINE_DIR"/libonnxruntime.so*; do
        [ -f "$f" ] && cp -a "$f" "$WORKDIR/usr/bin/"
      done
    fi
  else
    for f in "$ENGINE_DIR"/*.so*; do
      [ -f "$f" ] && cp -a "$f" "$WORKDIR/usr/bin/"
    done
  fi

  # Ensure SONAME symlinks exist (cp -a preserves them, but just in case)
  for lib in "$WORKDIR/usr/bin"/lib*.so.*; do
    soname=$(objdump -p "$lib" 2>/dev/null | sed -n 's/^\s*SONAME\s*//p')
    [ -n "$soname" ] && [ ! -e "$WORKDIR/usr/bin/$soname" ] && ln -sf "$(basename "$lib")" "$WORKDIR/usr/bin/$soname"
  done

  if [ "$PARAKEET" -eq 1 ]; then
    for f in "$MODEL_DIR"/*; do
      [ -f "$f" ] && cp -L "$f" "$WORKDIR/usr/share/models/"
    done
  else
    cp -L "${MODEL_FILES[0]}" "$WORKDIR/usr/share/models/model.gguf"
    if [ ${#MMPROJ_FILES[@]} -gt 0 ]; then
      cp -L "${MMPROJ_FILES[0]}" "$WORKDIR/usr/share/models/mmproj.gguf"
    fi
  fi

  local MODEL_SIZE
  if [ "$PARAKEET" -eq 1 ]; then
    MODEL_SIZE=$(du -sh "$MODEL_DIR" | cut -f1)
  else
    MODEL_SIZE=$(du -hL "${MODEL_FILES[0]}" | cut -f1)
  fi
  local HAS_GPU="$HAS_VULKAN"
  [ "$PARAKEET" -eq 1 ] && [ "$GPU" = "cuda" ] && HAS_GPU="cuda"

  sed -e "s/@NAME@/$OUTPUT_NAME/g" \
      -e "s/@MODEL_SIZE@/$MODEL_SIZE/g" \
      -e "s/@HAS_VULKAN@/$HAS_VULKAN/g" \
      -e "s/@HAS_GPU@/$HAS_GPU/g" \
      -e "s/@CTX_SIZE@/${CTX_SIZE:-0}/g" \
      -e "s/@BATCH_SIZE@/${BATCH_SIZE:-2048}/g" \
      -e "s/@SPEC_TYPE@/${SPEC_TYPE:-none}/g" \
      -e "s/@N_GPU_LAYERS@/${N_GPU_LAYERS:-0}/g" \
      -e "s/@MODEL_ALIAS@/${MODEL_ALIAS:-$OUTPUT_NAME}/g" \
      -e "s/@THREADS@/${THREADS:-12}/g" \
      -e "s/@BEST_OF@/${BEST_OF:-3}/g" \
      -e "s/@STREAM_MODE@/${STREAM_MODE:-0}/g" \
      -e "s/@STEP@/${STEP:-0}/g" \
      -e "s/@LENGTH@/${LENGTH:-30000}/g" \
      -e "s/@VTH@/${VTH:-0.6}/g" \
      -e "s/@SERVER_BIN@/$SERVER_BIN/g" \
      -e "s/@CLI_BIN@/$CLI_BIN/g" \
      -e "s/@IS_WHISPER@/$([[ "$IS_WHISPER" == [yY]* ]] && echo yes || echo no)/g" \
      -e "s/@IS_PARAKEET@/$([ "$PARAKEET" -eq 1 ] && echo yes || echo no)/g" \
      -e "s/@WORKERS@/${WORKERS:-2}/g" \
      -e "s/@GPU@/${GPU:-cpu}/g" \
      -e "s/@PRECISION@/$PRECISION/g" \
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
source "$SCRIPT_DIR/download-parakeet-models.sh"

# --- Download menu: pick model type first (decides files + engine) ---
download_menu() {
  echo "Select model type to download:"
  select t in "GGUF (llama.cpp)" "Whisper (whisper.cpp)" "Parakeet (ONNX)" "Cancel"; do
    case "$t" in
      "Cancel") echo "Aborted."; return 1 ;;
      "GGUF (llama.cpp)") download_gguf llama; return 0 ;;
      "Whisper (whisper.cpp)") download_gguf whisper; return 0 ;;
      "Parakeet (ONNX)") download_parakeet_models; return 0 ;;
      "") echo "Invalid selection" ;;
    esac
  done
}

# --- Collect models ---
MODELS=()
for d in "$PROJECT_DIR/models/"*/; do
  name="$(basename "$d")"
  gfiles=("$d"/*.gguf "$d"/ggml-*.bin "$d"/*.onnx)
  for gf in "${gfiles[@]}"; do [ -f "$gf" ] && { MODELS+=("$name"); break; }; done
done

# --- Parse args ---
if [ $# -ge 1 ]; then
  case "$1" in
    -h|--help)
      echo "Usage: $0 [model-folder] [-n name]"; echo "       $0 (interactive)"; echo "       $0 (-d|--download)"; exit 0 ;;
    -i|--interactive) ;;
    -d|--download) download_menu; exit 0 ;;
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
  download_menu
  exit 0
fi

echo "Select a model to package:"
select m in "Download GGUF model" "Download Whisper model" "Download Parakeet model" "${MODELS[@]}" "Cancel"; do
  case "$m" in
    "Cancel") echo "Aborted."; exit 0 ;;
    "Download GGUF model") download_gguf llama; break ;;
    "Download Whisper model") download_gguf whisper; break ;;
    "Download Parakeet model") download_parakeet_models; break ;;
    "") echo "Invalid selection" ;;
    *) build_model "$m" "$m"; break ;;
  esac
done
