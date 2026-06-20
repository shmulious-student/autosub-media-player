// LibraryPage — the media hub (SPEC §1). Open any video or add a folder, then
// play it with its generated Hebrew sidecar if one exists.
//
// File access goes through the system picker (file_selector → powerbox), which
// grants the sandboxed app access to user-selected files/folders. Picking a
// FOLDER grants its whole subtree for the session, so sibling `.srt` sidecars are
// readable — important under the App Sandbox (see lib/platform/secure_files.dart
// for persisting that access across launches).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../platform/secure_files.dart';
import '../player/player_page.dart';
import 'library_store.dart';
import 'processing_manager.dart';

const List<String> _videoExts = ['mkv', 'mp4', 'mov', 'm4v', 'avi', 'webm', 'ts', 'm2ts'];
const String _targetLang = 'he';
const String _engineDir = '/Volumes/EP2TB/autosub-media-player/engine';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.store, required this.manager});

  final LibraryStore store;
  final ProcessingManager manager;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
    widget.manager.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    widget.manager.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Per-title status line: ready / translating / queued / offline.
  ({String text, Color color}) _statusFor(LibraryEntry e) {
    if (e.hasSidecar(_targetLang)) {
      return (text: 'Hebrew subtitles ready', color: Colors.green.shade600);
    }
    final job = widget.manager.jobFor(e.path);
    if (job != null) {
      switch (job.state) {
        case 'running':
          final pct = (job.progress * 100).round();
          final stage = job.stage == null ? '' : ' · ${job.stage}';
          return (text: 'Translating… $pct%$stage', color: Colors.blue.shade600);
        case 'queued':
          return (text: 'Queued for translation', color: Colors.orange.shade700);
        case 'failed':
          return (text: 'Translation failed', color: Colors.red.shade600);
        case 'done':
          return (
            text: 'Translated (reopen the folder to load subs)',
            color: Colors.green.shade600
          );
      }
    }
    if (!widget.manager.engineOnline) {
      return (text: 'Engine offline', color: Colors.grey);
    }
    return (text: 'Waiting to translate…', color: Colors.orange.shade700);
  }

  Future<void> _openFile() async {
    // Native picker → grants sandboxed access + a persistable bookmark.
    final picked = await const SecureFiles().pickFile();
    if (picked == null) return;
    final entry = await widget.store.add(picked.path, bookmark: picked.bookmark);
    if (mounted) _play(entry);
  }

  Future<void> _addFolder() async {
    final picked = await const SecureFiles().pickFolder();
    if (picked == null) return;
    final videos = _scan(picked.path);
    // Every video in the folder shares the folder's bookmark, so resolving it on
    // the next launch re-grants access to the whole subtree (incl. sidecars).
    for (final v in videos) {
      await widget.store.add(v, bookmark: picked.bookmark);
    }
    if (mounted && videos.isEmpty) {
      _snack('No video files found in that folder.');
    }
  }

  List<String> _scan(String dir) {
    final out = <String>[];
    try {
      for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          final ext = p.extension(e.path).replaceFirst('.', '').toLowerCase();
          if (_videoExts.contains(ext)) out.add(e.path);
        }
      }
    } catch (_) {
      // Permission/IO issues → skip silently.
    }
    out.sort();
    return out;
  }

  void _play(LibraryEntry entry) {
    final sub = entry.hasSidecar(_targetLang) ? entry.sidecarPath(_targetLang) : null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          videoPath: entry.path,
          subtitlePath: sub,
          title: entry.fileName,
          autoPlay: true,
        ),
      ),
    );
  }

  void _copyGenerateCommand(LibraryEntry e) {
    // In-app generation needs the engine daemon (a sandboxed app can't spawn the
    // engine process). For now, surface the CLI that produces the sidecar.
    final cmd =
        "AUTOSUB_MODELS=/Volumes/EP2TB/autosub-models swift run --package-path $_engineDir "
        "AutoSubEngine process '${e.path}' --target $_targetLang --translator dictalm";
    Clipboard.setData(ClipboardData(text: cmd));
    _snack('Generate-subtitles command copied to clipboard.');
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final entries = widget.store.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Open a video',
            onPressed: _openFile,
            icon: const Icon(Icons.video_file),
          ),
          IconButton(
            tooltip: 'Add a folder',
            onPressed: _addFolder,
            icon: const Icon(Icons.create_new_folder),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!widget.manager.engineOnline) _offlineBanner(),
          Expanded(child: entries.isEmpty ? _empty() : _list(entries)),
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    const cmd =
        'AUTOSUB_MODELS=/Volumes/EP2TB/autosub-models swift run --package-path '
        '$_engineDir AutoSubEngine daemon';
    return Material(
      color: Colors.amber.shade100,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Engine daemon offline — background translation is paused. '
                'Start the daemon to translate your library.',
              ),
            ),
            TextButton(
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: cmd));
                _snack('Daemon start command copied to clipboard.');
              },
              child: const Text('Copy start command'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.movie_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('Your library is empty.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openFile,
              icon: const Icon(Icons.video_file),
              label: const Text('Open a video'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder),
              label: const Text('Add a folder'),
            ),
          ],
        ),
      );

  Widget _list(List<LibraryEntry> entries) => ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final e = entries[i];
          final status = _statusFor(e);
          return ListTile(
            leading: const Icon(Icons.movie),
            title: Text(e.fileName),
            subtitle: Text(status.text, style: TextStyle(color: status.color)),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'play':
                    _play(e);
                  case 'gen':
                    _copyGenerateCommand(e);
                  case 'remove':
                    widget.store.remove(e.path);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'play', child: Text('Play')),
                PopupMenuItem(
                    value: 'gen', child: Text('Copy generate-subtitles command')),
                PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
            onTap: () => _play(e),
          );
        },
      );
}
