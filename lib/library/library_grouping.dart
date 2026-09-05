// Library grouping — collapse episodes into seasons into series so the library
// shows one card per "main subject" (a series or a movie), with the season/episode
// hierarchy revealed inside (SPEC §5: ContextualParent series grouping).
//
// Grouping key: matched TV → the TMDB series id; unmatched files that parse as
// S/E → the parsed series title; everything else → standalone (movie / single file).

import '../metadata/filename_parser.dart';
import '../metadata/metadata_store.dart';
import '../metadata/title_metadata.dart';
import 'library_store.dart';

/// Season/episode for an entry: metadata first, then a filename parse.
({int? season, int? episode}) episodeNumberOf(
    LibraryEntry e, MetadataStore metadata) {
  final m = metadata.metadataFor(e.path);
  if (m != null && (m.season != null || m.episode != null)) {
    return (season: m.season, episode: m.episode);
  }
  final parsed = parseFilename(e.path);
  return (season: parsed.season, episode: parsed.episode);
}

bool _isSeriesEntry(LibraryEntry e, MetadataStore metadata) {
  final m = metadata.metadataFor(e.path);
  if (m != null) return m.isTv;
  return parseFilename(e.path).isSeries;
}

/// One row in the library: a series (with N episodes) or a standalone movie/file.
class LibraryGroup {
  LibraryGroup({
    required this.key,
    required this.isSeries,
    required this.title,
    required this.entries,
    this.posterFile,
    this.meta,
    this.year,
  });

  final String key;
  final bool isSeries;
  final String title;

  /// Episodes (series, sorted by season then episode) or a single file (movie).
  final List<LibraryEntry> entries;
  final String? posterFile;
  final TitleMetadata? meta;
  final int? year;

  LibraryEntry get representative => entries.first;
  int get count => entries.length;

  /// Distinct season numbers present (for the "S seasons · E episodes" line).
  int get seasonCount =>
      entries.map((e) => meta?.season).whereType<int>().toSet().length;
}

/// Group library [entries] into series + standalone cards.
List<LibraryGroup> groupLibrary(
    List<LibraryEntry> entries, MetadataStore metadata) {
  final buckets = <String, List<LibraryEntry>>{};
  final order = <String>[]; // preserve first-seen order for stable output

  // Stable series key: if ANY episode sharing a parsed title is TMDB-matched, key the
  // WHOLE title by that id — so enriched and not-yet-enriched episodes of one series
  // never split into two cards during background enrichment.
  final tmdbByTitle = <String, int>{};
  for (final e in entries) {
    final m = metadata.metadataFor(e.path);
    if (m != null && m.isTv && m.tmdbId != null) {
      tmdbByTitle[parseFilename(e.path).title.toLowerCase()] = m.tmdbId!;
    }
  }
  String seriesKeyFor(LibraryEntry e) {
    final t = parseFilename(e.path).title.toLowerCase();
    final id = tmdbByTitle[t];
    return id != null ? 'tv:$id' : 'tvname:$t';
  }

  for (final e in entries) {
    final key =
        _isSeriesEntry(e, metadata) ? seriesKeyFor(e) : 'file:${e.path}';
    if (!buckets.containsKey(key)) order.add(key);
    buckets.putIfAbsent(key, () => []).add(e);
  }

  final out = <LibraryGroup>[];
  for (final key in order) {
    final es = buckets[key]!;
    final isSeries = !key.startsWith('file:');
    // Representative metadata: prefer an entry that already has a poster.
    TitleMetadata? meta;
    for (final e in es) {
      final m = metadata.metadataFor(e.path);
      if (m != null && (meta == null || (m.posterFile != null && meta.posterFile == null))) {
        meta = m;
      }
    }
    final title = (meta?.name?.isNotEmpty ?? false)
        ? meta!.name!
        : (isSeries
            ? parseFilename(es.first.path).title
            : es.first.displayTitle);

    if (isSeries) {
      es.sort((a, b) {
        final na = episodeNumberOf(a, metadata);
        final nb = episodeNumberOf(b, metadata);
        final s = (na.season ?? 0).compareTo(nb.season ?? 0);
        return s != 0 ? s : (na.episode ?? 0).compareTo(nb.episode ?? 0);
      });
    }

    out.add(LibraryGroup(
      key: key,
      isSeries: isSeries,
      title: title,
      entries: es,
      posterFile: meta?.posterFile,
      meta: meta,
      year: meta?.year,
    ));
  }
  return out;
}

/// One season within a series, with its episodes (sorted).
class SeasonGroup {
  SeasonGroup({required this.season, required this.episodes});
  final int? season; // null when the file didn't parse a season
  final List<LibraryEntry> episodes;

  String get label => season != null ? 'Season $season' : 'Episodes';
}

/// Group a series' entries into seasons (sorted; episodes sorted within).
List<SeasonGroup> groupSeasons(LibraryGroup series, MetadataStore metadata) {
  final bySeason = <int?, List<LibraryEntry>>{};
  for (final e in series.entries) {
    final season = episodeNumberOf(e, metadata).season;
    bySeason.putIfAbsent(season, () => []).add(e);
  }
  final seasons = bySeason.keys.toList()
    ..sort((a, b) => (a ?? 1 << 30).compareTo(b ?? 1 << 30));
  return [
    for (final s in seasons)
      SeasonGroup(
        season: s,
        episodes: bySeason[s]!
          ..sort((a, b) => (episodeNumberOf(a, metadata).episode ?? 0)
              .compareTo(episodeNumberOf(b, metadata).episode ?? 0)),
      ),
  ];
}
