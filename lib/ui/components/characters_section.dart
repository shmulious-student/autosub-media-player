// CharactersSection — the rich Characters view for an enriched title.
//
// Shows each character with the portraying actor's photo, role, gender (the value
// the translator uses), and "main-ness" (billing / episode count). Cards sort by
// importance, billing order, or A–Z, and tap to open the actor — photo, the part's
// summary (the actor's TMDB bio, fetched lazily), and a link to TMDB.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../library/processing_manager.dart';
import '../../metadata/cast_member.dart';
import '../../metadata/metadata_store.dart';
import '../../metadata/tmdb_client.dart';
import '../bidi.dart';
import '../tokens.dart';
import 'toast.dart';

enum CharacterSort { importance, appearance, alphabetical }

extension _SortLabel on CharacterSort {
  String get label => switch (this) {
        CharacterSort.importance => 'Main role',
        CharacterSort.appearance => 'Billing',
        CharacterSort.alphabetical => 'A–Z',
      };
}

class CharactersSection extends StatefulWidget {
  const CharactersSection({
    super.key,
    required this.metadata,
    required this.manager,
    required this.path,
  });

  final MetadataStore metadata;
  final ProcessingManager manager;
  final String path;

  @override
  State<CharactersSection> createState() => _CharactersSectionState();
}

class _CharactersSectionState extends State<CharactersSection> {
  bool _busy = false;
  bool _summarizing = false;
  CharacterSort _sort = CharacterSort.importance;

  @override
  void initState() {
    super.initState();
    widget.metadata.addListener(_onChange);
    widget.metadata.ensureCredits(widget.path); // lazily populate cast on open
  }

  @override
  void dispose() {
    widget.metadata.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refetch() async {
    setState(() => _busy = true);
    await widget.metadata.refetch(widget.path);
    if (!mounted) return;
    setState(() => _busy = false);
    final n = widget.metadata.metadataFor(widget.path)?.cast.length ?? 0;
    showToast(
      context,
      n == 0 ? 'No cast found for this title.' : 'Refetched $n characters.',
      variant: n == 0 ? ToastVariant.attention : ToastVariant.success,
    );
  }

  Future<void> _summarizeRoles() async {
    final m = widget.metadata.metadataFor(widget.path);
    if (m == null || m.cast.isEmpty) return;
    if (!widget.manager.engineOnline) {
      showToast(context, 'Engine offline — can\'t generate summaries now.',
          variant: ToastVariant.attention);
      return;
    }
    setState(() => _summarizing = true);
    final names = m.cast.map((c) => c.displayCharacter).toList();
    final summaries = await widget.manager.engine.characterSummaries(
      title: m.name ?? '',
      year: m.year,
      overview: m.overview,
      characters: names,
    );
    await widget.metadata.setCharacterSummaries(widget.path, summaries);
    if (!mounted) return;
    setState(() => _summarizing = false);
    showToast(
      context,
      summaries.isEmpty
          ? 'Could not generate role summaries.'
          : 'Generated ${summaries.length} role summaries.',
      variant: summaries.isEmpty ? ToastVariant.attention : ToastVariant.success,
    );
  }

  List<CastMember> _sorted(List<CastMember> cast) {
    final list = [...cast];
    switch (_sort) {
      case CharacterSort.importance:
        list.sort((a, b) {
          final byEp = (b.episodeCount ?? 0).compareTo(a.episodeCount ?? 0);
          return byEp != 0 ? byEp : a.order.compareTo(b.order);
        });
      case CharacterSort.appearance:
        list.sort((a, b) => a.order.compareTo(b.order));
      case CharacterSort.alphabetical:
        list.sort((a, b) => a.displayCharacter
            .toLowerCase()
            .compareTo(b.displayCharacter.toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metadata.metadataFor(widget.path);
    final matched = m?.hasMatch ?? false;
    final cast = _sorted(m?.cast ?? const []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Characters', style: AppType.title),
            const SizedBox(width: AppSpacing.x3),
            if (cast.isNotEmpty)
              Text('${cast.length}',
                  style: AppType.body.copyWith(color: AppColors.textSecondary)),
            const Spacer(),
            if (cast.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: AppSpacing.x2),
                child: OutlinedButton.icon(
                  onPressed: _summarizing ? null : _summarizeRoles,
                  icon: _summarizing
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Summarize roles'),
                ),
              ),
            OutlinedButton.icon(
              onPressed:
                  (!matched || !widget.metadata.hasApiKey || _busy) ? null : _refetch,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_sync_outlined, size: 18),
              label: const Text('Refetch'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          'Cast genders feed the translator so named people get correct gendered '
          'grammar. Tap a character for the actor & their bio.',
          style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.x4),
        if (cast.isEmpty)
          Text(
            matched
                ? 'No character data yet. Tap Refetch to pull the cast.'
                : 'Match this title to TMDB first (Fix match) to load characters.',
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          )
        else ...[
          Wrap(
            spacing: AppSpacing.x2,
            children: [
              for (final s in CharacterSort.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: _sort == s,
                  onSelected: (_) => setState(() => _sort = s),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          for (final c in cast) _castRow(c),
        ],
      ],
    );
  }

  Widget _castRow(CastMember c) {
    final meta = <String>[
      if (c.episodeCount != null && c.episodeCount! > 0)
        '${c.episodeCount} ep${c.episodeCount == 1 ? '' : 's'}',
      c.actor,
    ].join(' · ');

    return InkWell(
      onTap: () => _openActor(c),
      borderRadius: AppRadius.borderSm,
      child: Container(
        margin: const EdgeInsetsDirectional.only(bottom: AppSpacing.x2),
        padding: const EdgeInsets.all(AppSpacing.x2),
        decoration: BoxDecoration(
          color: AppColors.neutral850,
          borderRadius: const BorderRadius.all(AppRadius.sm),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Row(
          children: [
            _photo(c.profilePath, 40, 56),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AutoDirText(c.displayCharacter, style: AppType.body),
                  const SizedBox(height: 2),
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodySm
                          .copyWith(color: AppColors.textSecondary)),
                  if (c.roleSummary != null && c.roleSummary!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    AutoDirText(c.roleSummary!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.bodySm.copyWith(
                            color: AppColors.textPrimary,
                            fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            _genderBadge(c.gender),
          ],
        ),
      ),
    );
  }

  Widget _genderBadge(String gender) {
    if (gender != 'm' && gender != 'f') {
      return const Text('—', style: TextStyle(color: AppColors.textSecondary));
    }
    final isF = gender == 'f';
    final color = isF ? const Color(0xFFE091C4) : const Color(0xFF6FB1E0);
    return Container(
      width: 22, height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.20),
        shape: BoxShape.circle,
      ),
      child: Text(isF ? '♀' : '♂', style: AppType.body.copyWith(color: color)),
    );
  }

  Widget _photo(String? profilePath, double w, double h) {
    final url = TmdbClient.profileUrl(profilePath);
    return ClipRRect(
      borderRadius: AppRadius.borderSm,
      child: SizedBox(
        width: w,
        height: h,
        child: url == null
            ? _photoPlaceholder()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _photoPlaceholder(),
                loadingBuilder: (ctx, child, progress) =>
                    progress == null ? child : _photoPlaceholder(),
              ),
      ),
    );
  }

  Widget _photoPlaceholder() => const ColoredBox(
        color: AppColors.neutral800,
        child: Icon(Icons.person, size: 20, color: AppColors.neutral500),
      );

  void _openActor(CastMember c) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.neutral900,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ActorSheet(metadata: widget.metadata, member: c),
    );
  }
}

class _ActorSheet extends StatelessWidget {
  const _ActorSheet({required this.metadata, required this.member});

  final MetadataStore metadata;
  final CastMember member;

  @override
  Widget build(BuildContext context) {
    final url = TmdbClient.profileUrl(member.profilePath, 'w342');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.x6, 0, AppSpacing.x6, AppSpacing.x6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(AppRadius.sm),
                  child: SizedBox(
                    width: 96, height: 144,
                    child: url == null
                        ? const ColoredBox(
                            color: AppColors.neutral800,
                            child: Icon(Icons.person,
                                size: 36, color: AppColors.neutral500))
                        : Image.network(url, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const ColoredBox(
                                color: AppColors.neutral800,
                                child: Icon(Icons.person,
                                    size: 36, color: AppColors.neutral500))),
                  ),
                ),
                const SizedBox(width: AppSpacing.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AutoDirText(member.displayCharacter, style: AppType.title),
                      const SizedBox(height: AppSpacing.x1),
                      AutoDirText('Played by ${member.actor}',
                          style: AppType.body
                              .copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: AppSpacing.x2),
                      Text(
                        [
                          if (member.gender == 'm') 'Male'
                          else if (member.gender == 'f') 'Female'
                          else 'Gender unknown',
                          if (member.episodeCount != null && member.episodeCount! > 0)
                            '${member.episodeCount} episodes',
                        ].join(' · '),
                        style: AppType.bodySm
                            .copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x4),
            Text('Role in the plot', style: AppType.body),
            const SizedBox(height: AppSpacing.x2),
            AutoDirText(
              (member.roleSummary?.isNotEmpty ?? false)
                  ? member.roleSummary!
                  : 'Not generated yet — use “Summarize roles” in the list above. '
                      '(AI summary, grounded in the plot overview.)',
              style: AppType.body.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.x4),
            Text('About the actor', style: AppType.body),
            const SizedBox(height: AppSpacing.x2),
            FutureBuilder<String?>(
              future: metadata.personBio(member.personId),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.x2),
                    child: SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                final bio = snap.data;
                return AutoDirText(
                  bio == null || bio.isEmpty
                      ? 'No biography available on TMDB for ${member.actor}.'
                      : bio,
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
            const SizedBox(height: AppSpacing.x4),
            Row(
              children: [
                const Icon(Icons.link, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: SelectableText(
                    member.tmdbUrl,
                    style: AppType.bodySm.copyWith(color: AppColors.amber),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy link',
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: member.tmdbUrl));
                    showToast(context, 'TMDB link copied.');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
