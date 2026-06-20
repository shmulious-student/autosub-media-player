#!/usr/bin/env bash
#
# dev-run.sh — rebuild the Swift engine and launch the macOS app.
#
# The app's EngineSupervisor spawns the engine DAEMON as a child
# (engine/.build/debug/AutoSubEngine daemon), kills stale ones first, restarts it
# if it dies, and stops it when the app quits. So "launch the app" already brings
# the daemon up — we just have to rebuild the engine binary first so the app
# launches the CURRENT code.
#
# Usage:
#   scripts/dev-run.sh                 rebuild engine, then run the macOS app (+daemon)
#   scripts/dev-run.sh --engine-only   rebuild + run JUST the daemon in the foreground
#                                      with live logs (no UI) — handy for debugging
#   scripts/dev-run.sh --release       build the engine in release mode
#
# Model weights live ONLY on the external drive (docs/MODELS.md); the engine fails
# loudly if it's not mounted.

set -euo pipefail

# Repo root = parent of this script's dir (portable, no hardcoded path).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

export AUTOSUB_MODELS="${AUTOSUB_MODELS:-/Volumes/EP2TB/autosub-models}"
export HF_HOME="${HF_HOME:-$AUTOSUB_MODELS/hf-cache}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$AUTOSUB_MODELS/hf-cache}"

ENGINE_ONLY=0
SWIFT_CONFIG="debug"   # app's dev fallback launches .build/debug/AutoSubEngine
for arg in "$@"; do
  case "$arg" in
    --engine-only) ENGINE_ONLY=1 ;;
    --release)     SWIFT_CONFIG="release" ;;
    -h|--help)     sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Preflight: the engine is useless without its model weights. ---
if [ ! -d "$AUTOSUB_MODELS/llm" ]; then
  echo "✗ AUTOSUB_MODELS not found at '$AUTOSUB_MODELS/llm'." >&2
  echo "  Is the external drive mounted? (docs/MODELS.md)" >&2
  exit 1
fi
command -v llama-server >/dev/null 2>&1 || \
  echo "⚠ llama-server not on PATH — translation will fail until it's installed (brew install llama.cpp)." >&2

# --- 1. Rebuild the engine. ---
# Heavy compute lives in llama-server + CoreML (separate optimized binaries), not
# in the Swift orchestrator, so a debug build is fine for throughput.
echo "▶ building engine ($SWIFT_CONFIG)…"
( cd "$REPO/engine" && swift build -c "$SWIFT_CONFIG" )
ENGINE_BIN="$REPO/engine/.build/$SWIFT_CONFIG/AutoSubEngine"
echo "  built: $ENGINE_BIN"

# --- 2a. Engine-only mode: run the daemon in the foreground with logs. ---
if [ "$ENGINE_ONLY" -eq 1 ]; then
  echo "▶ starting daemon on 127.0.0.1:${AUTOSUB_DAEMON_PORT:-8770} (Ctrl-C to stop)…"
  pkill -f 'AutoSubEngine daemon' 2>/dev/null || true
  exec "$ENGINE_BIN" daemon
fi

# --- 2b. Full app: it spawns the freshly built daemon as a child. ---
# If we built --release, point the supervisor at it (its dev fallback is debug-only).
if [ "$SWIFT_CONFIG" = "release" ]; then
  export AUTOSUB_ENGINE_BIN="$ENGINE_BIN"
fi
echo "▶ launching macOS app (it will start + supervise the daemon)…"
cd "$REPO"
flutter pub get
exec flutter run -d macos
