// LibraryStore — the app-side list of media the user has added (SPEC §1).
//
// v0: a simple JSON-persisted list of file paths the user opened, so the Library
// isn't limited to the hardcoded sample. Each entry can carry a security-scoped
// `bookmark` (see lib/platform/secure_files.dart, added by the file-access work)
// so access survives across launches under the App Sandbox.
//
// The Mac engine remains the source of truth for processed artifacts; this is a
// lightweight client-side index of what the user has in their library UI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../common/app_paths.dart';
import '../platform/secure_files.dart';

/// One media item in the library.
class LibraryEntry {
  LibraryEntry({required this.path, this.bookmark, required this.addedAtMs});

  /// Absolute path to the video file.
  final String path;

  /// Base64-encoded security-scoped bookmark to the file, or null if the app
  /// has direct filesystem access.
  final String? bookmark;

  /// Epoch ms when this entry was added.
  final int addedAtMs;

  String get fileName => p.basename(path);

  /// A cleaner display name: the base filename without extension, with common
  /// separators turned into spaces (e.g. "Foundation.S02E01" → "Foundation S02E01").
  /// TMDB metadata will refine this later (SCREENS §3).
  String get displayTitle => p
      .basenameWithoutExtension(path)
      .replaceAll(RegExp(r'[._]+'), ' ')
      .trim();

  /// Sidecar subtitle path for [lang], next to the media (SPEC: portable sidecar).
  String sidecarPath(String lang) =>
      p.join(p.dirname(path), '${p.basenameWithoutExtension(path)}.$lang.srt');

  /// Whether a generated sidecar exists for [lang] (best-effort; under the
  /// sandbox, sibling access depends on a folder bookmark).
  bool hasSidecar(String lang) {
    try {
      return File(sidecarPath(lang)).existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toJson() =>
      {'path': path, 'bookmark': bookmark, 'addedAtMs': addedAtMs};

  factory LibraryEntry.fromJson(Map<String, dynamic> j) => LibraryEntry(
        path: j['path'] as String,
        bookmark: j['bookmark'] as String?,
        addedAtMs: (j['addedAtMs'] as num?)?.toInt() ?? 0,
      );
}

/// A persisted, observable list of [LibraryEntry]s.
class LibraryStore extends ChangeNotifier {
  LibraryStore({File? storeFile}) : _file = storeFile;

  final List<LibraryEntry> _entries = [];
  List<LibraryEntry> get entries => List.unmodifiable(_entries);

  File? _file;

  Future<File> _storeFile() async {
    if (_file != null) return _file!;
    return _file = AutoSubPaths.libraryFile();
  }

  /// Load the persisted library (call once at startup).
  Future<void> load() async {
    try {
      final f = await _storeFile();
      if (!f.existsSync()) return;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      _entries
        ..clear()
        ..addAll(list.map((e) => LibraryEntry.fromJson(e as Map<String, dynamic>)));
      await _reacquireAccess();
      notifyListeners();
    } catch (_) {
      // Corrupt/missing store → start empty.
    }
  }

  /// Re-establish sandboxed access to persisted entries by resolving each
  /// security-scoped bookmark (no UI). Distinct bookmarks only (folder bookmarks
  /// are shared across many entries). Stale bookmarks just fail quietly — the
  /// user can re-add the title.
  Future<void> _reacquireAccess() async {
    const secure = SecureFiles();
    final seen = <String>{};
    for (final e in _entries) {
      final b = e.bookmark;
      if (b == null || !seen.add(b)) continue;
      try {
        await secure.resolveBookmark(b);
      } catch (_) {
        // Native channel unavailable (e.g. non-macOS) or stale bookmark.
      }
    }
  }

  Future<void> _save() async {
    final f = await _storeFile();
    await f.writeAsString(jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  /// Add a media path (dedup by path). Newest first.
  Future<LibraryEntry> add(String path, {String? bookmark, int? nowMs}) async {
    _entries.removeWhere((e) => e.path == path);
    final entry = LibraryEntry(
      path: path,
      bookmark: bookmark,
      addedAtMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
    _entries.insert(0, entry);
    await _save();
    notifyListeners();
    return entry;
  }

  Future<void> remove(String path) async {
    _entries.removeWhere((e) => e.path == path);
    await _save();
    notifyListeners();
  }

  /// Remove every entry from the library (does not delete media or sidecars).
  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries.clear();
    await _save();
    notifyListeners();
  }
}
