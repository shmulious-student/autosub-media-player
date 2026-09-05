// Fix-match dialog (SCREENS §8). Low-confidence auto-match → search TMDB → reassign
// so the title's poster + metadata are the genuine, official ones. The network call
// is named to the user ("Searching TMDB…", principle P4).

import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/components/tmdb_match_row.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import 'metadata_store.dart';
import 'tmdb_client.dart';

Future<void> showFixMatchDialog(
  BuildContext context, {
  required MetadataStore metadata,
  required String path,
  required String initialQuery,
  int? currentTmdbId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FixMatchDialog(
      metadata: metadata,
      path: path,
      initialQuery: initialQuery,
      currentTmdbId: currentTmdbId,
    ),
  );
}

class _FixMatchDialog extends StatefulWidget {
  const _FixMatchDialog({
    required this.metadata,
    required this.path,
    required this.initialQuery,
    required this.currentTmdbId,
  });

  final MetadataStore metadata;
  final String path;
  final String initialQuery;
  final int? currentTmdbId;

  @override
  State<_FixMatchDialog> createState() => _FixMatchDialogState();
}

class _FixMatchDialogState extends State<_FixMatchDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  bool _loading = false;
  List<TmdbResult> _results = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _search(widget.initialQuery);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.metadata.search(q);
      if (mounted) setState(() => _results = r);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reach TMDB. Retry.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(TmdbResult r) async {
    await widget.metadata.assignMatch(widget.path, r);
    if (mounted) {
      Navigator.of(context).pop();
      showToast(context, 'Match updated.', variant: ToastVariant.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.neutral850,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Fix match', style: AppType.title),
              const SizedBox(height: AppSpacing.x4),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                onSubmitted: _search,
                style: AppType.body,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Search TMDB by title',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.x3),
              Flexible(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.x6),
        child: Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: AppSpacing.x3),
            Text('Searching TMDB…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.x4),
        child: Row(
          children: [
            Expanded(
                child: Text(_error!,
                    style: AppType.body.copyWith(color: AppColors.failedFg))),
            TextButton(
                onPressed: () => _search(_controller.text),
                child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Text('No results — try a different title or year.',
            style: AppType.body.copyWith(color: AppColors.textSecondary)),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x1),
      itemBuilder: (context, i) {
        final r = _results[i];
        return TmdbMatchRow(
          name: r.name,
          year: r.year,
          mediaType: r.mediaType,
          posterUrl: r.posterUrl('w185'),
          voteAverage: r.voteAverage,
          overview: r.overview,
          isCurrent: r.id == widget.currentTmdbId,
          onSelect: () => _select(r),
        );
      },
    );
  }
}
