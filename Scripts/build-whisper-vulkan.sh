#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$PROJECT_DIR/Engines/whisper.cpp"

log()  { echo -e "\033[0;32m[build]\033[0m $1"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $1"; }
err()  { echo -e "\033[0;31m[error]\033[0m $1"; }

detect_pm() {
  command -v pacman >/dev/null && echo "pacman" && return
  command -v apt-get >/dev/null && echo "apt" && return
  echo "unknown"
}

pm=$(detect_pm)

install_deps() {
  case "$pm" in
    pacman)
      sudo pacman -S --noconfirm \
        base-devel cmake git \
        shaderc spirv-headers vulkan-headers vulkan-loader
      ;;
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y -qq \
        build-essential cmake git \
        shaderc libvulkan-dev
      if ! dpkg -l spirv-headers 2>/dev/null >/dev/null; then
        log "SPIRV-Headers cmake config not found, installing from source..."
        tmpdir=$(mktemp -d)
        git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git "$tmpdir/spirv-headers"
        cmake -S "$tmpdir/spirv-headers" -B "$tmpdir/spirv-headers/build"
        sudo cmake --install "$tmpdir/spirv-headers/build"
        rm -rf "$tmpdir"
      fi
      ;;
    *)
      err "Unsupported package manager: $pm"
      err "Install manually: cmake, git, shaderc/glslc, vulkan-headers, spirv-headers"
      exit 1
      ;;
  esac
}

log "Installing build dependencies..."
install_deps

BUILD_DIR="/tmp/whisper-cpp-build"
SRC_DIR="/tmp/whisper-cpp-src"

if [ ! -d "$SRC_DIR" ]; then
  log "Cloning whisper.cpp..."
  git clone --depth=1 https://github.com/ggml-org/whisper.cpp.git "$SRC_DIR"
fi

log "Configuring with Vulkan support..."
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_COREML=OFF \
  -DWHISPER_OPENVINO=OFF

log "Building ($(nproc) threads)..."
cmake --build "$BUILD_DIR" --config Release -j "$(nproc)"

log "Installing to $ENGINE_DIR..."
mkdir -p "$ENGINE_DIR"

for exe in whisper-cli whisper-server whisper-quantize whisper-bench \
           whisper-vad-speech-segments parakeet-cli parakeet-quantize main bench; do
  find "$BUILD_DIR" -name "$exe" -type f 2>/dev/null -exec cp -v {} "$ENGINE_DIR/" \;
done

for lib in libwhisper.so libggml-base.so libggml-cpu.so libggml.so libggml-vulkan.so; do
  find "$BUILD_DIR" -name "$lib*" -type f 2>/dev/null -exec cp -v {} "$ENGINE_DIR/" \;
done

# Link .so -> .so.N for the loaders
find "$ENGINE_DIR" -maxdepth 1 -name "lib*.so.*.*" -type f 2>/dev/null | while read -r f; do
  base=$(sed 's/\.so\..*/.so/' <<< "$(basename "$f")")
  soname="${f%.*}"
  [ ! -e "$ENGINE_DIR/$base" ]  && ln -sf "$(basename "$f")" "$ENGINE_DIR/$base"
  [ ! -e "$soname" ]            && ln -sf "$(basename "$f")" "$soname"
done

rm -rf "$BUILD_DIR" "$SRC_DIR"

log "Verifying..."
output=$("$ENGINE_DIR/whisper-cli" --version 2>&1) || true
if echo "$output" | grep -qi "vulkan"; then
  log "GPU (Vulkan) build successful!"
elif echo "$output" | grep -qi "whisper.cpp"; then
  warn "Build succeeded but Vulkan device not detected (expected on headless systems)."
  log "CPU fallback will handle inference."
else
  err "Build verification failed:"
  echo "$output"
  exit 1
fi

echo ""
log "whisper.cpp Vulkan build complete."
