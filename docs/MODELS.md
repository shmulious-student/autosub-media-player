# Model storage — external drive only

**Hard rule:** every heavyweight local model (ASR + translation LLMs, plus any
download caches) lives on the **external drive**, never on the internal Mac disk
or in `~`. They are multi-GB and must not fill the system volume.

## Canonical location

```
/Volumes/EP2TB/autosub-models/
├── whisper/      # whisper.cpp / faster-whisper GGML/CT2 weights (fallback path)
├── whisperkit/   # WhisperKit CoreML model bundles
├── llm/          # GGUF weights for llama.cpp (DictaLM 3.0, Qwen) + MLX exports
├── hf-cache/     # Hugging Face download cache (HF_HOME)
└── ollama/       # Ollama model store, if Ollama is ever used
```

This directory is **outside the git repo** (weights are never committed).

## Make runtimes obey it

Source these before running any model download or the Mac engine. They redirect
the default caches (which otherwise go to `~/.cache`, `~/Library`, etc.) onto the
external drive:

```sh
export AUTOSUB_MODELS=/Volumes/EP2TB/autosub-models

# Hugging Face (transformers, huggingface_hub, MLX model pulls)
export HF_HOME="$AUTOSUB_MODELS/hf-cache"
export HUGGINGFACE_HUB_CACHE="$AUTOSUB_MODELS/hf-cache"

# Ollama (if used)
export OLLAMA_MODELS="$AUTOSUB_MODELS/ollama"
```

- **whisper.cpp / GGUF (llama.cpp):** there is no env default — always pass an
  explicit `--model /Volumes/EP2TB/autosub-models/...` path. The Mac engine must
  resolve all model paths from `$AUTOSUB_MODELS`, never bundle weights in the app.
- **WhisperKit:** set its download/model folder to `$AUTOSUB_MODELS/whisperkit`
  in code (the API accepts a custom model location) instead of the default app
  support directory.
- **MLX:** pulls via Hugging Face, so `HF_HOME` above already covers it.

## Implementation note
The Mac engine should read `AUTOSUB_MODELS` (default
`/Volumes/EP2TB/autosub-models`) at startup and fail loudly if the drive is not
mounted, rather than silently re-downloading weights to the internal disk.
