#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$PROJECT_DIR/Engines/whisper.cpp"

log()  { echo -e "\033[0;32m[stream]\033[0m $1"; }
err()  { echo -e "\033[0;31m[error]\033[0m $1"; }

if [ ! -f "$ENGINE_DIR/libwhisper.so" ]; then
    err "whisper.cpp engine not found in $ENGINE_DIR"
    err "Run install-engine.sh first."
    exit 1
fi

detect_pm() {
  command -v pacman >/dev/null && echo "pacman" && return
  command -v apt-get >/dev/null && echo "apt" && return
  echo "unknown"
}

pm=$(detect_pm)

install_deps() {
  case "$pm" in
    pacman)
      sudo pacman -S --noconfirm sdl2
      ;;
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y -qq libsdl2-dev
      ;;
    *)
      err "Unsupported package manager: $pm"
      err "Install SDL2 manually, then re-run this script."
      exit 1
      ;;
  esac
}

cleanup_deps() {
  case "$pm" in
    apt)
      log "Removing build-time SDL2 dependencies..."
      sudo apt-get remove -y -qq libsdl2-dev
      sudo apt-get autoremove -y -qq
      ;;
  esac
}

BUILD_DIR="/tmp/whisper-stream-build"
SRC_DIR="/tmp/whisper-stream-src"

log "Installing build dependencies..."
install_deps

if [ ! -d "$SRC_DIR" ]; then
  log "Cloning whisper.cpp..."
  git clone --depth=1 https://github.com/ggml-org/whisper.cpp.git "$SRC_DIR"
fi

log "Configuring with SDL2..."
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DWHISPER_SDL2=ON \
  -DCMAKE_BUILD_TYPE=Release

log "Building whisper-stream ($(nproc) threads)..."
cmake --build "$BUILD_DIR" --config Release -j "$(nproc)" --target whisper-stream

log "Installing to $ENGINE_DIR..."
cp -v "$BUILD_DIR/bin/whisper-stream" "$ENGINE_DIR/"

log "Cleaning up..."
rm -rf "$BUILD_DIR" "$SRC_DIR"
cleanup_deps

log "Verifying..."
if [ -x "$ENGINE_DIR/whisper-stream" ]; then
  log "whisper-stream installed successfully!"
else
  err "whisper-stream binary not found!"
  exit 1
fi
