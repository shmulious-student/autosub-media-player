// SubtitleEditorPage — edit a generated `.srt` sidecar line-by-line (SCREENS §5).
//
// Loads the cues from the sidecar (RTL controls stripped for editing), shows each
// as a SubtitleLineRow with a CPS gauge, and writes the edits back in the engine's
// own format (RLE…PDF re-applied for RTL targets). Pure local editing — per-line
// AI re-translate needs the engine and is left as a disabled affordance for now.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/components/empty_state.dart';
import '../ui/components/subtitle_line_row.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import 'srt.dart';

class SubtitleEditorPage extends StatefulWidget {
  const SubtitleEditorPage({
    super.key,
    required this.sidecarPath,
    required this.title,
    required this.targetLang,
    required this.maxCps,
  });

  final String sidecarPath;
  final String title;
  final String targetLang;
  final int maxCps;

  @override
  State<SubtitleEditorPage> createState() => _SubtitleEditorPageState();
}

class _SubtitleEditorPageState extends State<SubtitleEditorPage> {
  List<SrtCue> _cues = const [];
  final List<TextEditingController> _controllers = [];
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  String? _error;

  bool get _rtl => kRtlLanguages.contains(widget.targetLang);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.sidecarPath);
      if (!file.existsSync()) {
        setState(() {
          _loading = false;
          _error = 'No subtitle file found for this title.';
        });
        return;
      }
      final cues = parseSrt(await file.readAsString());
      _controllers
        ..clear()
        ..addAll(cues.map((c) => TextEditingController(text: c.text)));
      setState(() {
        _cues = cues;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = "Couldn't read the subtitle file.";
      });
    }
  }

  void _onLineChanged(int i, String value) {
    final cue = _cues[i];
    if (cue.text == value) return;
    cue.text = value;
    cue.userEdited = true;
    setState(() => _dirty = true);
  }

  int get _overCpsCount =>
      _cues.where((c) => c.cps > widget.maxCps).length;
  int get _editedCount => _cues.where((c) => c.userEdited).length;

  /// Extend one cue so it reads within budget (without overlapping neighbors).
  void _fixTiming(int i) {
    final res = syncCueTiming(_cues, i, widget.maxCps);
    if (res == null) {
      showToast(context, 'No room to extend — try shortening the text.',
          variant: ToastVariant.attention);
      return;
    }
    setState(() {
      _cues[i].start = res.start;
      _cues[i].end = res.end;
      _cues[i].userEdited = true;
      _dirty = true;
    });
  }

  /// Fix every over-CPS line that has room to extend.
  void _fixAllTiming() {
    var n = 0;
    for (var i = 0; i < _cues.length; i++) {
      final res = syncCueTiming(_cues, i, widget.maxCps);
      if (res != null) {
        _cues[i].start = res.start;
        _cues[i].end = res.end;
        _cues[i].userEdited = true;
        n++;
      }
    }
    if (n > 0) {
      setState(() => _dirty = true);
      showToast(context, 'Adjusted timing on $n line${n == 1 ? '' : 's'}.',
          variant: ToastVariant.success);
    } else {
      showToast(context, 'Nothing to extend — try shortening the text.',
          variant: ToastVariant.info);
    }
  }

  Future<void> _save() async {
    if (!_dirty || _saving) return;
    setState(() => _saving = true);
    try {
      final out = serializeSrt(_cues, rtl: _rtl);
      await File(widget.sidecarPath).writeAsString(out);
      if (mounted) {
        setState(() {
          _saving = false;
          _dirty = false;
        });
        showToast(context, 'Subtitles saved.', variant: ToastVariant.success);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, "Couldn't save the subtitle file.",
            variant: ToastVariant.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.neutral950,
          appBar: AppBar(
            backgroundColor: AppColors.neutral950,
            elevation: 0,
            leading: BackButton(onPressed: () => Navigator.of(context).pop()),
            title: Text('Edit subtitles · ${widget.title}',
                style: AppType.subtitle),
            actions: [
              if (_overCpsCount > 0) ...[
                Center(
                  child: Text('$_overCpsCount over-CPS',
                      style: AppType.bodySm
                          .copyWith(color: AppColors.attentionFg)),
                ),
                const SizedBox(width: AppSpacing.x3),
                OutlinedButton.icon(
                  onPressed: _fixAllTiming,
                  icon: const Icon(Icons.auto_fix_high, size: 16),
                  label: const Text('Fix all timing'),
                ),
                const SizedBox(width: AppSpacing.x3),
              ],
              Padding(
                padding: const EdgeInsetsDirectional.only(end: AppSpacing.x4),
                child: FilledButton.icon(
                  onPressed: _dirty && !_saving ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(_dirty ? 'Save (⌘S) · $_editedCount' : 'Saved'),
                ),
              ),
            ],
          ),
          body: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.subtitles_off_outlined,
        title: _error!,
        message: 'Generate subtitles for this title first.',
      );
    }
    if (_cues.isEmpty) {
      return const EmptyState(
        icon: Icons.subtitles_off_outlined,
        title: 'No lines to edit.',
        message: 'This subtitle file is empty.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.x12),
      itemCount: _cues.length,
      itemBuilder: (context, i) {
        final cue = _cues[i];
        // Offer "Fix timing" only when the line is over-CPS AND there's room to
        // extend it (the mechanism already knows it reads too fast).
        final canFix = cue.cps > widget.maxCps &&
            syncCueTiming(_cues, i, widget.maxCps) != null;
        return SubtitleLineRow(
          index: i + 1,
          start: formatTimecode(cue.start),
          end: formatTimecode(cue.end),
          controller: _controllers[i],
          cps: cue.cps,
          maxCps: widget.maxCps,
          edited: cue.userEdited,
          onChanged: (v) => _onLineChanged(i, v),
          onFixTiming: canFix ? () => _fixTiming(i) : null,
        );
      },
    );
  }
}
