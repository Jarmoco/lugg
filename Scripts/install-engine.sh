#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$PROJECT_DIR/Engine"

FORCE=0

# Check: x86_64 architecture
if [ "$(uname -m)" != "x86_64" ]; then
  echo "Error: $(uname -m) is not supported. This script only supports x86_64 (x64) systems."
  echo "Please manually download a llama.cpp release compatible with your hardware:"
  echo "  https://github.com/ggml-org/llama.cpp/releases"
  exit 1
fi

# Check: NVIDIA GPU (try lspci → nvidia-smi → lsmod)
if ! lspci 2>/dev/null | grep -qi nvidia &&
   ! nvidia-smi 2>/dev/null >/dev/null &&
   ! lsmod 2>/dev/null | grep -qi nvidia; then
  echo "Error: no NVIDIA GPU detected. This script supports x64 Vulkan (NVIDIA) only."
  echo "Please manually download a llama.cpp release for your GPU from:"
  echo "  https://github.com/ggml-org/llama.cpp/releases"
  exit 1
fi
[ "${1:-}" = "--force" ] && FORCE=1

if [ -f "$ENGINE_DIR/llama-server" ] && [ "$FORCE" -eq 0 ]; then
  echo "Engine already has llama-server. Use --force to reinstall."
  exit 0
fi

echo "Fetching latest llama.cpp release info..."
RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest)
TAG=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+')
ASSET_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]*vulkan-x64\.tar\.gz')

[ -z "$TAG" ] && echo "Error: could not parse release tag" && exit 1
[ -z "$ASSET_URL" ] && echo "Error: no Vulkan x64 tarball found for $TAG" && exit 1

echo "Latest: $TAG"
echo "Asset:  $(basename "$ASSET_URL")"

TARBALL="/tmp/llama-${TAG}.tar.gz"
if [ ! -f "$TARBALL" ] || [ "$FORCE" -eq 1 ]; then
  echo "Downloading..."
  curl -fSL -o "$TARBALL" "$ASSET_URL"
fi

echo "Extracting to Engine/..."
mkdir -p "$ENGINE_DIR"
rm -rf "$ENGINE_DIR"/* "$ENGINE_DIR"/.* 2>/dev/null || true
tar -xzf "$TARBALL" -C "$ENGINE_DIR" --strip-components=1

echo "Engine updated to $TAG ($(du -sh "$ENGINE_DIR" | cut -f1))"
