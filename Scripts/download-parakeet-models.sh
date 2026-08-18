#!/bin/bash
# Parakeet ONNX model downloader - source from build.sh or run standalone

[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

HF_BASE="https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main"
SILERO_URL="https://github.com/snakers4/silero-vad/raw/v6.2.1/src/silero_vad/data/silero_vad.onnx"

download_parakeet_models() {
  local PRECISION
  read -p "Model precision (int8 [recommended] / fp32): " PRECISION
  case "${PRECISION,,}" in
    fp32|f32) PRECISION="fp32" ;;
    *)        PRECISION="int8" ;;
  esac

  local DEFAULT_NAME="parakeet-tdt-0.6b-v3-$PRECISION"
  local FOLDER_NAME
  read -p "Model folder name [$DEFAULT_NAME]: " FOLDER_NAME
  FOLDER_NAME="${FOLDER_NAME:-$DEFAULT_NAME}"

  local MODEL_DIR="$PROJECT_DIR/models/$FOLDER_NAME"
  mkdir -p "$MODEL_DIR"

  local FILES=("config.json" "vocab.txt" "nemo128.onnx")
  if [ "$PRECISION" = "fp32" ]; then
    FILES+=("encoder-model.onnx" "encoder-model.onnx.data" "decoder_joint-model.onnx")
  else
    FILES+=("encoder-model.int8.onnx" "decoder_joint-model.int8.onnx")
  fi

  echo "Downloading $PRECISION models to $MODEL_DIR..."
  for f in "${FILES[@]}"; do
    echo "  $f"
    curl -fSL -o "$MODEL_DIR/$f" "$HF_BASE/$f"
  done
  echo "  silero_vad.onnx"
  curl -fSL -o "$MODEL_DIR/silero_vad.onnx" "$SILERO_URL"

  echo "Done: $MODEL_DIR ($(du -sh "$MODEL_DIR" | cut -f1))"

  read -p "Build AppImage now? (Y/n): " BUILD_NOW
  if [ "$BUILD_NOW" != "n" ] && type build_model &>/dev/null; then
    build_model "$FOLDER_NAME" "$FOLDER_NAME"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  download_parakeet_models
fi
