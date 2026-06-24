#!/bin/bash
# Hugging Face GGUF downloader - source from build.sh or run standalone

[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

download_gguf() {
  local REPO_ID
  read -p "Hugging Face repo ID (e.g., bartowski/Llama-3.2-1B-Instruct-GGUF): " REPO_ID
  [ -z "$REPO_ID" ] && echo "Aborted." && return 1

  echo "Fetching file list..."
  local DATA
  DATA=$(curl -sf "https://huggingface.co/api/models/$REPO_ID/tree/main") || {
    echo "Error: could not fetch repo info (check repo ID)"
    return 1
  }

  local -a NAMES=() SIZES=()
  while IFS=$'\t' read -r name size; do
    NAMES+=("$name"); SIZES+=("$size")
  done < <(echo "$DATA" | jq -r '.[] | select(.path | endswith(".gguf")) | [.path, .size] | @tsv')

  [ ${#NAMES[@]} -eq 0 ] && echo "No .gguf files found in that repo." && return 1

  echo
  echo "Select a GGUF file to download:"
  local -a ITEMS=()
  for i in "${!NAMES[@]}"; do
    local hr
    hr=$(numfmt --to=iec "${SIZES[$i]}" 2>/dev/null || echo "${SIZES[$i]} bytes")
    ITEMS+=("${NAMES[$i]} ($hr)")
  done

  select sel in "${ITEMS[@]}" "Cancel"; do
    [ "$sel" = "Cancel" ] && echo "Aborted." && return 1
    [ -z "$sel" ] && echo "Invalid selection" && continue
    local idx
    for i in "${!ITEMS[@]}"; do
      [ "${ITEMS[$i]}" = "$sel" ] && idx=$i && break
    done
    local CHOSEN_NAME="${NAMES[$idx]}"
    break
  done

  local DEFAULT_NAME
  DEFAULT_NAME="$(basename "$REPO_ID" | sed 's/-GGUF$//; s/-Instruct$//')"
  local FOLDER_NAME
  read -p "Model folder name [$DEFAULT_NAME]: " FOLDER_NAME
  FOLDER_NAME="${FOLDER_NAME:-$DEFAULT_NAME}"

  local MODEL_DIR="$PROJECT_DIR/models/$FOLDER_NAME"
  mkdir -p "$MODEL_DIR"
  if [ -f "$MODEL_DIR/$CHOSEN_NAME" ]; then
    read -p "$CHOSEN_NAME already exists in $FOLDER_NAME. Overwrite? (y/N): " confirm
    [ "$confirm" != "y" ] && echo "Aborted." && return 1
  fi

  echo "Downloading $CHOSEN_NAME..."
  (cd "$MODEL_DIR" && curl -L -O "https://huggingface.co/$REPO_ID/resolve/main/$CHOSEN_NAME")

  echo "Downloaded to $MODEL_DIR/$CHOSEN_NAME"

  read -p "Build AppImage now? (Y/n): " BUILD_NOW
  if [ "$BUILD_NOW" != "n" ] && type build_model &>/dev/null; then
    build_model "$FOLDER_NAME" "$FOLDER_NAME"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  download_gguf
fi
