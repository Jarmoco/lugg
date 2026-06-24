# lugg

Portable AI — package llama.cpp and GGUF models into self-contained **AppImages**.

Download a model, pack it with an engine, run it anywhere. One AppImage per model.

## Structure

```
├── AppRun.template         # AppImage entry point template
├── Engine/                 # llama.cpp binaries (installed by install-engine.sh)
├── models/                 # Model folders with .gguf files
├── Scripts/
│   ├── build.sh            # Package model → AppImage
│   ├── install-engine.sh   # Download latest llama.cpp vulkan-x64 release
│   └── huggingface.sh      # Download GGUF files from Hugging Face
└── dist/                   # Built .AppImage files
```

## Quick Start

Just run:
```sh
./Scripts/build.sh
```

You'll be prompted to configure performance defaults for the model. The resulting AppImage bundles llama-server + the model. Run it anywhere:

```sh
./dist/ModelName-x86_64.AppImage
```

From a file manager, double-clicking opens a terminal window with the server logs — close it to stop.

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

You can download mmproj files from Hugging Face repos alongside the main GGUF model — the build script picks them up automatically.

## Requirements

- **OS**: Linux (currently only x86_64)
- **GPU**: The script automatically downloads the Vulkan backend version of llama.cpp — CPU fallback works but is slow. If your system is not x86_64 + Nvidia GPU, you have to manually download the llama.cpp version compatible with your hardware and extract into Engine/
- **Deps**: bash, curl, [jq](https://github.com/jqlang/jq/releases), [appimagetool](https://github.com/AppImage/appimagetool/releases)