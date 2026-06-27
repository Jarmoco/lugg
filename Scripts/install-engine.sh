#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINES_DIR="$PROJECT_DIR/Engines"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

install_llama_cpp() {
  local ENGINE_DIR="$ENGINES_DIR/llama.cpp"

  if [ "$(uname -m)" != "x86_64" ]; then
    echo "Skipping llama.cpp: $(uname -m) not supported." >&2
    echo "See https://github.com/ggml-org/llama.cpp/releases" >&2
    return
  fi

  if ! lspci 2>/dev/null | grep -qi nvidia &&
     ! nvidia-smi 2>/dev/null >/dev/null &&
     ! lsmod 2>/dev/null | grep -qi nvidia; then
    echo "Skipping llama.cpp: no NVIDIA GPU detected." >&2
    echo "See https://github.com/ggml-org/llama.cpp/releases" >&2
    return
  fi

  if [ -f "$ENGINE_DIR/llama-server" ] && [ "$FORCE" -eq 0 ]; then
    echo "llama.cpp already installed. Use --force to reinstall."
    return
  fi

  echo "Fetching latest llama.cpp release info..."
  local RELEASE_JSON TAG ASSET_URL
  RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest)
  TAG=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+')
  ASSET_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]*vulkan-x64\.tar\.gz')

  [ -z "$TAG" ] && echo "Error: could not parse release tag" && exit 1
  [ -z "$ASSET_URL" ] && echo "Error: no Vulkan x64 tarball found for $TAG" && exit 1

  echo "Latest: $TAG"
  echo "Asset:  $(basename "$ASSET_URL")"

  local TARBALL="/tmp/llama-${TAG}.tar.gz"
  if [ ! -f "$TARBALL" ] || [ "$FORCE" -eq 1 ]; then
    echo "Downloading..."
    curl -fSL -o "$TARBALL" "$ASSET_URL"
  fi

  echo "Extracting to Engines/llama.cpp/..."
  mkdir -p "$ENGINE_DIR"
  rm -rf "$ENGINE_DIR"/* "$ENGINE_DIR"/.* 2>/dev/null || true
  tar -xzf "$TARBALL" -C "$ENGINE_DIR" --strip-components=1

  echo "llama.cpp updated to $TAG ($(du -sh "$ENGINE_DIR" | cut -f1))"
}

install_whisper_cpp() {
  local ENGINE_DIR="$ENGINES_DIR/whisper.cpp"

  if [ "$(uname -m)" != "x86_64" ]; then
    echo "Skipping whisper.cpp: $(uname -m) not supported." >&2
    return
  fi

  if [ -f "$ENGINE_DIR/whisper-server" ] && [ "$FORCE" -eq 0 ]; then
    echo "whisper.cpp already installed. Use --force to reinstall."
    return
  fi

  # Offer GPU build if NVIDIA GPU is present
  if lspci 2>/dev/null | grep -qi nvidia ||
     nvidia-smi 2>/dev/null >/dev/null ||
     lsmod 2>/dev/null | grep -qi nvidia; then
    echo ""
    echo "NVIDIA GPU detected. Vulkan GPU support can accelerate whisper.cpp."
    read -r -p "Build with Vulkan GPU support? [Y/n] " reply
    case "${reply,,}" in
      n|no) ;;
      *)
        echo "Building whisper.cpp with Vulkan GPU support..."
        bash "$SCRIPT_DIR/build-whisper-vulkan.sh"
        echo "whisper.cpp GPU build installed ($(du -sh "$ENGINE_DIR" | cut -f1))"
        return
        ;;
    esac
  fi

  echo "Fetching latest whisper.cpp release info..."
  local RELEASE_JSON TAG ASSET_URL
  RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest)
  TAG=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+')
  ASSET_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]*ubuntu-x64\.tar\.gz')

  [ -z "$TAG" ] && echo "Error: could not parse release tag" && exit 1
  [ -z "$ASSET_URL" ] && echo "Error: no ubuntu-x64 tarball found for $TAG" && exit 1

  echo "Latest: $TAG"
  echo "Asset:  $(basename "$ASSET_URL")"

  local TARBALL="/tmp/whisper-${TAG}.tar.gz"
  if [ ! -f "$TARBALL" ] || [ "$FORCE" -eq 1 ]; then
    echo "Downloading..."
    curl -fSL -o "$TARBALL" "$ASSET_URL"
  fi

  echo "Extracting to Engines/whisper.cpp/..."
  mkdir -p "$ENGINE_DIR"
  rm -rf "$ENGINE_DIR"/* "$ENGINE_DIR"/.* 2>/dev/null || true
  tar -xzf "$TARBALL" -C "$ENGINE_DIR" --strip-components=1

  echo "whisper.cpp updated to $TAG ($(du -sh "$ENGINE_DIR" | cut -f1))"
}

install_llama_cpp
install_whisper_cpp

echo "All engines installed."
