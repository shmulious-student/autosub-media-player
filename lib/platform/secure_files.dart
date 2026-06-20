// SecureFiles — Dart wrapper over the native macOS security-scoped file bridge.
//
// Under the App Sandbox the app can only read files the user explicitly grants
// via the system file picker (powerbox). To keep that access across launches we
// mint an *app-scoped security-scoped bookmark* for each picked file/folder.
//
// Usage contract:
//   1. Call [pickFile] / [pickFolder] to let the user grant access. Persist the
//      returned `bookmark` (base64) alongside the `path` (the library store does
//      this — see V0.md). The `path` is for display/identity; the `bookmark` is
//      what actually re-grants sandboxed access.
//   2. On the NEXT launch, before reading the file, call [resolveBookmark] with
//      the persisted bookmark. It re-establishes a security-scoped resource and
//      returns the resolved filesystem path to read from.
//
// Native side: `macos/Runner/SecureFilesPlugin.swift`,
// MethodChannel `autosub/secure_files`.

import 'package:flutter/services.dart';

/// Bridges to the native `autosub/secure_files` MethodChannel for sandbox-correct
/// file/folder picking and persistent security-scoped bookmark resolution.
class SecureFiles {
  const SecureFiles();

  static const MethodChannel _channel = MethodChannel('autosub/secure_files');

  /// Open the system file picker (files only). Returns the chosen file's `path`
  /// and a base64 security-scoped `bookmark` to persist, or `null` if cancelled.
  Future<({String path, String bookmark})?> pickFile() => _pick('pickFile');

  /// Open the system file picker (directories only). Returns the chosen folder's
  /// `path` and a base64 security-scoped `bookmark` to persist, or `null` if
  /// cancelled.
  Future<({String path, String bookmark})?> pickFolder() => _pick('pickFolder');

  /// Re-establish access to a previously bookmarked file/folder. Pass the base64
  /// `bookmark` that was persisted from [pickFile] / [pickFolder]. Returns the
  /// resolved filesystem path (begin reading from it), or `null` if the bookmark
  /// could not be resolved (e.g. the file moved/was deleted — re-pick to refresh).
  Future<String?> resolveBookmark(String bookmark) async {
    final path = await _channel.invokeMethod<String>(
      'resolveBookmark',
      <String, dynamic>{'bookmark': bookmark},
    );
    return path;
  }

  Future<({String path, String bookmark})?> _pick(String method) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(method);
    if (result == null) return null;
    final path = result['path'] as String?;
    final bookmark = result['bookmark'] as String?;
    if (path == null || bookmark == null) return null;
    return (path: path, bookmark: bookmark);
  }
}
