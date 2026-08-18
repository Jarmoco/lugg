#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINES_DIR="$PROJECT_DIR/Engines"

# Usage: install-engine.sh [--force] [llama|whisper|parakeet ...]
#   --force            reinstall even if already present
#   engine names       install only those engines
#   (no engine names)  install all engines (default)
FORCE=0
WANTED=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    llama|whisper|parakeet) WANTED+=("$arg") ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

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
  local BUILT=0

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
        BUILT=1
        ;;
    esac
  fi

  if [ "$BUILT" -eq 0 ]; then
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
  fi

  bash "$SCRIPT_DIR/build-whisper-stream.sh"
}

# Fetch a wheel from PyPI (used for NVIDIA redistributable runtime libraries)
fetch_nvidia_wheel() { # $1=pkg $2=destdir
  local pkg="$1" dest="$2" url
  url=$(curl -fsSL "https://pypi.org/pypi/${pkg}/json" \
    | jq -r '[ .urls[]
        | select(.packagetype == "bdist_wheel")
        | select(.filename | test("(many)?linux.*(x86_64|amd64)"))
      ] | sort_by(.upload_time) | reverse | .[0].url')
  [ -z "$url" ] && echo "  Error: no Linux x86_64 wheel found for $pkg" >&2 && return 1
  curl -fSL -o "$dest/$(basename "$url")" "$url"
}

# Bundle the CUDA 12.x + cuDNN 9 runtime libraries ORT's CUDA EP dlopens at
# runtime. Sourced from NVIDIA's redistributable pip wheels (the same set the
# onnxruntime-gpu[cuda,cudnn] extras install). Only the kernel driver stays on
# the host.
install_parakeet_cuda_libs() { # $1=engine_dir
  local ENGINE_DIR="$1"
  local CUDA_DIR="$ENGINE_DIR/cuda" pkg WORK EXTRACT wheel
  mkdir -p "$CUDA_DIR"

  local PKGS=(nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cufft-cu12 \
              nvidia-curand-cu12 nvidia-cusolver-cu12 nvidia-cusparse-cu12 \
              nvidia-cuda-nvrtc-cu12 nvidia-nccl-cu12 nvidia-cudnn-cu12)

  # Process one wheel at a time so /tmp never holds all wheels + extracts
  # at once (the full set is ~3.6 GB and /tmp is often a small tmpfs).
  for pkg in "${PKGS[@]}"; do
    WORK="$(mktemp -d)"
    EXTRACT="$WORK/x"
    echo "  downloading $pkg..."
    if ! fetch_nvidia_wheel "$pkg" "$WORK"; then
      rm -rf "$WORK"
      return 1
    fi
    wheel="$(find "$WORK" -name '*.whl' -print -quit)"
    echo "  extracting $pkg..."
    if command -v unzip >/dev/null; then
      unzip -oq "$wheel" '*/lib/*.so*' -d "$EXTRACT"
    else
      python3 -m zipfile -e "$wheel" "$EXTRACT"
    fi
    find "$EXTRACT" -name '*.so*' -type f -exec cp -a {} "$CUDA_DIR/" \;
    rm -rf "$WORK"
  done

  # cuDNN 9 needs zlib on Linux; bundle the host's if available
  local ZLIB
  ZLIB=$(find /usr/lib /lib /usr/local/lib -maxdepth 4 -name 'libz.so.1.*' -type f 2>/dev/null | head -1)
  if [ -n "$ZLIB" ]; then
    cp -a "$ZLIB" "$CUDA_DIR/"
    ln -sf "$(basename "$ZLIB")" "$CUDA_DIR/libz.so.1"
  fi

  echo "  CUDA/cuDNN runtime libs installed to $CUDA_DIR ($(du -sh "$CUDA_DIR" | cut -f1))"
}

install_parakeet_ort() { # $1=engine_dir $2=suffix(""|"-gpu") $3=version
  local ENGINE_DIR="$1" SUFFIX="$2" VER="$3"
  local TARBALL="/tmp/onnxruntime${SUFFIX}-${VER}.tgz"
  local DIR="/tmp/onnxruntime-linux-x64${SUFFIX}-${VER}"
  curl -fSL -o "$TARBALL" "https://github.com/microsoft/onnxruntime/releases/download/v${VER}/onnxruntime-linux-x64${SUFFIX}-${VER}.tgz"
  tar -xzf "$TARBALL" -C /tmp
  if [ -n "$SUFFIX" ]; then
    cp -a "$DIR/lib/libonnxruntime.so.${VER}" "$ENGINE_DIR/libonnxruntime${SUFFIX}.so.${VER}"
    ln -sf "libonnxruntime${SUFFIX}.so.${VER}" "$ENGINE_DIR/libonnxruntime${SUFFIX}.so.1"
    ln -sf "libonnxruntime${SUFFIX}.so.1" "$ENGINE_DIR/libonnxruntime${SUFFIX}.so"
    # ORT >= 1.17 ships the CUDA EP as split provider libs that the main lib
    # dlopens at runtime; without them the CUDA provider fails to load.
    cp -a "$DIR"/lib/libonnxruntime_providers_*.so "$ENGINE_DIR/"
  else
    cp -a "$DIR"/lib/libonnxruntime.so* "$ENGINE_DIR/"
  fi
  rm -rf "$TARBALL" "$DIR"
}

install_parakeet() {
  local ENGINE_DIR="$ENGINES_DIR/parakeet"

  if [ "$(uname -m)" != "x86_64" ]; then
    echo "Skipping parakeet: $(uname -m) not supported." >&2
    return
  fi

  if [ -f "$ENGINE_DIR/parakeet" ] && [ "$FORCE" -eq 0 ]; then
    echo "parakeet already installed. Use --force to reinstall."
    return
  fi

  echo "Fetching latest achetronic/parakeet release info..."
  local RELEASE_JSON TAG ASSET_URL
  RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/achetronic/parakeet/releases/latest)
  TAG=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+')
  ASSET_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]*linux-amd64')

  [ -z "$TAG" ] && echo "Error: could not parse release tag" && exit 1
  [ -z "$ASSET_URL" ] && echo "Error: no linux-amd64 asset found for $TAG" && exit 1

  local ONNX_VERSION="1.25.1"

  # Offer CUDA GPU support if an NVIDIA GPU is present
  local WANT_GPU=0
  if lspci 2>/dev/null | grep -qi nvidia ||
     nvidia-smi 2>/dev/null >/dev/null ||
     lsmod 2>/dev/null | grep -qi nvidia; then
    echo ""
    echo "NVIDIA GPU detected. CUDA can accelerate parakeet."
    echo "This bundles the CUDA 12.x + cuDNN 9 runtime libs; only the NVIDIA"
    echo "kernel driver stays on the host (driver >= 570.26 required)."
    read -r -p "Install with CUDA GPU support? [y/N] " reply
    case "${reply,,}" in
      y|yes) WANT_GPU=1 ;;
    esac
  fi

  mkdir -p "$ENGINE_DIR"
  rm -rf "$ENGINE_DIR"/* "$ENGINE_DIR"/.* 2>/dev/null || true

  echo "Downloading parakeet server $TAG..."
  curl -fSL -o "$ENGINE_DIR/parakeet" "$ASSET_URL"
  chmod +x "$ENGINE_DIR/parakeet"

  echo "Downloading ONNX Runtime v${ONNX_VERSION} (CPU)..."
  install_parakeet_ort "$ENGINE_DIR" "" "$ONNX_VERSION"

  if [ "$WANT_GPU" -eq 1 ]; then
    echo "Downloading ONNX Runtime v${ONNX_VERSION} (CUDA)..."
    install_parakeet_ort "$ENGINE_DIR" "-gpu" "$ONNX_VERSION"
    echo "Downloading CUDA 12.x + cuDNN 9 runtime libraries..."
    if ! install_parakeet_cuda_libs "$ENGINE_DIR"; then
      echo "Error: could not fetch CUDA/cuDNN runtime libraries (needs unzip or python3)." >&2
      exit 1
    fi
    touch "$ENGINE_DIR/.gpu"
  fi

  echo "parakeet updated to $TAG with ONNX Runtime v${ONNX_VERSION} ($(du -sh "$ENGINE_DIR" | cut -f1))"
}

# Install only requested engines, or all of them by default
run_engine() {
  local eng="$1"
  case "$eng" in
    llama)    install_llama_cpp ;;
    whisper)  install_whisper_cpp ;;
    parakeet) install_parakeet ;;
  esac
}

if [ ${#WANTED[@]} -eq 0 ]; then
  run_engine llama
  run_engine whisper
  run_engine parakeet
else
  for eng in "${WANTED[@]}"; do
    run_engine "$eng"
  done
fi

echo "All requested engines installed."
