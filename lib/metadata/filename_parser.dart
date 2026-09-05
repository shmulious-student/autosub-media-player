// Filename parser — turn a media filename into a TMDB query (SCREENS §8: "pre-filled
// query from filename parse"). Best-effort: extracts a clean title, optional year,
// and season/episode for series, stripping the usual release/quality noise.

import 'package:path/path.dart' as p;

class ParsedName {
  const ParsedName({
    required this.title,
    this.year,
    this.season,
    this.episode,
  });

  final String title;
  final int? year;
  final int? season;
  final int? episode;

  bool get isSeries => season != null && episode != null;

  /// The query string for TMDB search.
  String get query => title;
}

// Common release/quality tokens to drop from the tail of a title.
final RegExp _noise = RegExp(
  r'\b(1080p|2160p|720p|480p|4k|uhd|hdr|x264|x265|h264|h265|hevc|aac|ac3|dts|'
  r'bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|web|hdrip|dvdrip|remux|'
  r'proper|repack|extended|uncut|imax|amzn|nf|hulu|dsnp|atvp|yts|rarbg|'
  r'multi|dual|hebsub|heb|eng|subbed|dubbed)\b',
  caseSensitive: false,
);

final RegExp _seasonEp = RegExp(
  r'[sS](\d{1,2})[\s._-]*[eE](\d{1,3})|(\d{1,2})x(\d{2,3})',
);

final RegExp _year = RegExp(r'(?<![\d])(19\d{2}|20\d{2})(?![\d])');

/// Parse [path]'s filename into a [ParsedName].
ParsedName parseFilename(String path) {
  // Normalize separators to spaces (keep brackets so we can detect a year inside
  // "(2021)" before dropping release groups).
  final name =
      p.basenameWithoutExtension(path).replaceAll(RegExp(r'[._]+'), ' ');

  int? season, episode, year;
  int? cutAt;

  // Season/episode (cut the title before it).
  final se = _seasonEp.firstMatch(name);
  if (se != null) {
    season = int.tryParse(se.group(1) ?? se.group(3) ?? '');
    episode = int.tryParse(se.group(2) ?? se.group(4) ?? '');
    cutAt = se.start;
  }

  // Year: the LAST plausible 4-digit year wins, so a number that's part of the
  // title (e.g. "Blade Runner 2049 2017") doesn't get mistaken for the year.
  final years = _year.allMatches(name).toList();
  if (years.isNotEmpty) {
    final ym = years.last;
    year = int.tryParse(ym.group(1)!);
    cutAt = (cutAt == null) ? ym.start : (ym.start < cutAt ? ym.start : cutAt);
  }

  var title = cutAt != null ? name.substring(0, cutAt) : name;
  // Drop bracketed release groups, leftover bracket chars, noise tokens, then tidy.
  title = title.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
  title = title.replaceAll(RegExp(r'[\[\]\(\)\{\}]'), ' ');
  title = title.replaceAll(_noise, ' ');
  title = title.replaceAll(RegExp(r'\s*-\s*$'), ' ');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (title.isEmpty) {
    title = name
        .replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ')
        .replaceAll(_noise, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  return ParsedName(
    title: title,
    year: year,
    season: season,
    episode: episode,
  );
}
