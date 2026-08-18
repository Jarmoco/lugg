# lugg

Package llama.cpp and GGUF models into self-contained **AppImages**.

Download a model, pack it with llama.cpp, run it anywhere. One AppImage per model.

## Structure

```
├── AppRun.template         # AppImage entry point template
├── Engines/                # Inference engines e.g. llama.cpp (installed by install-engine.sh)
├── models/                 # Model folders with .gguf files
├── Scripts/
│   ├── build.sh            # Package model → AppImage
│   ├── install-engine.sh   # Download/update all engine binaries (llama.cpp, whisper.cpp, …)
│   ├── huggingface.sh      # Download GGUF / Whisper files from Hugging Face
│   └── download-parakeet-models.sh  # Download Parakeet ONNX models
└── dist/                   # Built .AppImage files
```

## Quick Start

Clone the repo and run the build.sh script. 
It will automatically download the latest llama.cpp release (x86_64 Vulkan only) and help you in downloading GGUFs from huggingface, given a repo id.

```sh
git clone https://github.com/Jarmoco/lugg.git
cd lugg
./Scripts/build.sh
```

You'll be prompted to configure performance defaults for the model. The resulting AppImage bundles llama-server + the model. Run it anywhere:

```sh
./dist/ModelName-x86_64.AppImage
```

From a file manager, double-clicking opens a terminal window with the server logs, close it to stop.

## Usage

### Building

During `./Scripts/build.sh` you can set default parameters:

| Prompt | Default | Description |
|---|---|---|
| Context size | `0` (model default) | Maximum tokens in context window |
| Batch size | `2048` | Tokens processed per batch |
| Speculative decoding type | `none` | Draft model strategy (see `--help` in AppImage for values) |
| GPU layers | `99` (Vulkan) / `0` (CPU) | Layers offloaded to GPU |
| Model alias | model folder name | Display name shown in the API |
| CPU threads | `4` | Number of CPU threads |

All of these can be overridden at runtime.

### Engines

`./Scripts/install-engine.sh` installs the inference engines (llama.cpp, whisper.cpp, parakeet). By default it installs all of them; pass one or more engine names to install only those:

```sh
./Scripts/install-engine.sh parakeet        # only the parakeet engine
./Scripts/install-engine.sh llama whisper   # llama.cpp + whisper.cpp
./Scripts/install-engine.sh --force parakeet  # reinstall even if present
```

`build.sh` also auto-installs the engine for the model you're packaging (and only that one) when it's missing.

### AppImage Runtime

| Flag | Behavior |
|---|---|
| (none) | Starts llama-server on port 9976 with baked-in defaults |
| `--port N` | Custom port |
| `--ctx-size N` | Override context size (default: build-time value) |
| `--batch-size N` | Override batch size |
| `--spec-type TYPES` | Speculative decoding type (values: `none`, `draft-simple`, `draft-eagle3`, `draft-mtp`, `ngram-simple`, `ngram-map-k`, `ngram-map-k4v`, `ngram-mod`, `ngram-cache`) |
| `--n-gpu-layers N` | Override GPU layers (only takes effect if Vulkan is available) |
| `--threads N` | Override CPU threads |
| `--cli` | Interactive chat mode (llama-cli) |
| `--help` | Usage |

### Multimodal Models (mmproj)

If the model folder contains a GGUF file with `mmproj` in its name (e.g. `Qwen3.5-0.8B-MTP/mmproj-Qwen3.5-0.8B-MTP-Q4_K_M.gguf`), the build script automatically detects it and bundles it into the AppImage. The runtime then passes `--mmproj` to llama-server, enabling image input support.

You can download mmproj files from Hugging Face repos alongside the main GGUF model, the build script picks them up automatically.

### Parakeet (speech recognition)

Model folders containing `.onnx` files are detected as Parakeet models and packaged with the [achetronic/parakeet](https://github.com/achetronic/parakeet) server (OpenAI Whisper-compatible API).

- **Download models**: `./Scripts/build.sh` asks which model type to download — **GGUF (llama.cpp)**, **Whisper (whisper.cpp)** or **Parakeet (ONNX)** — then fetches the right files. For GGUF/Whisper you pick from the repo's files (one per quant). Parakeet: pick "Download Parakeet model" from the menu, or run `./Scripts/download-parakeet-models.sh`. Int8 (~670MB) is the default; **fp32 (~2.5GB)** is the choice for full accuracy on GPU.
- **Engine**: `install-engine.sh` installs the parakeet server binary + `libonnxruntime.so` into `Engines/parakeet/` automatically. If an NVIDIA GPU is detected it offers a **CUDA build**, which bundles the CUDA 12.x + cuDNN 9 runtime libraries (from NVIDIA's redistributable pip wheels) — only the kernel driver stays on the host (driver ≥ 570.26 required).
- **GPU AppImage**: answer `cuda` to the "GPU provider" prompt when building, then run with `--gpu cuda`. CUDA libs and the GPU ONNX Runtime are bundled; workers default to 1 (~3GB VRAM each with fp32). CPU AppImages only bundle the CPU runtime.
- **API**: `POST /v1/audio/transcriptions` (WAV always; MP3/OGG/etc. via host `ffmpeg`), `GET /v1/models`, `GET /health`.
- **Runtime flags**: `--port`, `--workers`, `--gpu` (cpu/cuda).

## Requirements

- **OS**: Linux (currently only x86_64)
- **GPU**: The script automatically downloads the Vulkan backend version of llama.cpp — CPU fallback works but is slow. If your system is not x86_64 + Nvidia GPU, you have to manually download the llama.cpp version compatible with your hardware and extract into Engines/llama.cpp/
- **Deps**: bash, curl, [jq](https://github.com/jqlang/jq/releases), [appimagetool](https://github.com/AppImage/appimagetool/releases)
