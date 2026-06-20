# AutoSub Media Player — dev tasks.
#
# Model weights live ONLY on the external drive (docs/MODELS.md). The engine
# resolves them from $AUTOSUB_MODELS and fails loudly if the drive is unmounted.
# Source these before any model download or engine run.

export AUTOSUB_MODELS ?= /Volumes/EP2TB/autosub-models
export HF_HOME        ?= $(AUTOSUB_MODELS)/hf-cache
export HUGGINGFACE_HUB_CACHE ?= $(AUTOSUB_MODELS)/hf-cache
export OLLAMA_MODELS  ?= $(AUTOSUB_MODELS)/ollama

.PHONY: help engine-build engine-run engine-test app-get app-run app-test analyze all-test

help:
	@echo "AutoSub Media Player — make targets"
	@echo "  make engine-build   Build the Swift Mac engine (SwiftPM)"
	@echo "  make engine-run     Run the engine daemon (stub)"
	@echo "  make engine-test    Run engine unit tests"
	@echo "  make app-get        flutter pub get"
	@echo "  make app-run        Run the Flutter app on macOS"
	@echo "  make app-test       Run Flutter widget tests"
	@echo "  make analyze        flutter analyze"
	@echo "  make all-test       Engine + app tests"
	@echo ""
	@echo "  AUTOSUB_MODELS = $(AUTOSUB_MODELS)"

# --- Mac native engine (engine/) ---

engine-build:
	cd engine && swift build

engine-run:
	cd engine && AUTOSUB_MODELS=$(AUTOSUB_MODELS) swift run AutoSubEngine

engine-test:
	cd engine && swift test

# --- Flutter app shell ---

app-get:
	flutter pub get

app-run:
	flutter run -d macos

app-test:
	flutter test

analyze:
	flutter analyze

all-test: engine-test app-test
