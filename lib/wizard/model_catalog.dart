// Model catalog — the AI models AutoSub keeps on the external drive (MODELS.md).
//
// Each entry maps to a subdirectory under the model root (engine ModelPaths.swift:
// whisperkit / llm / llm-fast). Presence is a real local check — the dir exists and
// has content — so the first-run wizard reports honest status without a network call.

import 'dart:io';

import 'package:path/path.dart' as p;

class ModelInfo {
  const ModelInfo({
    required this.name,
    required this.subdir,
    required this.approxSize,
    required this.purpose,
    this.required = true,
  });

  final String name;
  final String subdir; // under the model root
  final String approxSize; // human-readable, e.g. "7 GB"
  final String purpose;
  final bool required;
}

/// The v1 model set. Sizes are approximate (commercial-licensed only — Whisper
/// MIT, DictaLM Apache, per the project's licensing constraint).
const List<ModelInfo> kModelCatalog = [
  ModelInfo(
    name: 'WhisperKit (Large v3)',
    subdir: 'whisperkit',
    approxSize: '1.5 GB',
    purpose: 'Speech recognition',
  ),
  ModelInfo(
    name: 'DictaLM 3.0 (12B)',
    subdir: 'llm',
    approxSize: '7 GB',
    purpose: 'Hebrew translation',
  ),
  ModelInfo(
    name: 'DictaLM (fast)',
    subdir: 'llm-fast',
    approxSize: '4 GB',
    purpose: 'Faster translation',
    required: false,
  ),
];

/// True if [model] is present (its subdir under [root] exists and is non-empty).
bool isModelPresent(String root, ModelInfo model) {
  try {
    final dir = Directory(p.join(root, model.subdir));
    if (!dir.existsSync()) return false;
    return dir.listSync().isNotEmpty;
  } catch (_) {
    return false;
  }
}
