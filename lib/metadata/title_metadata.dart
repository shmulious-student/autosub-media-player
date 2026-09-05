// TitleMetadata — the per-title TMDB enrichment the library renders: official
// name, year, overview, a locally-cached official poster, and the colors extracted
// from that poster (which tint the title's detail page). Keyed by media file path.

import 'package:flutter/painting.dart';

import 'cast_member.dart';

class TitleMetadata {
  const TitleMetadata({
    required this.path,
    this.tmdbId,
    this.mediaType,
    this.name,
    this.year,
    this.season,
    this.episode,
    this.overview,
    this.voteAverage,
    this.originalLanguage,
    this.posterPath,
    this.posterFile,
    this.dominantColor,
    this.accentColor,
    this.characters = const {},
    this.cast = const [],
    this.confidence = 0,
    this.fetchedAtMs = 0,
    this.searched = false,
  });

  final String path;
  final int? tmdbId;
  final String? mediaType; // 'movie' | 'tv'
  final String? name;
  final int? year;
  final int? season;
  final int? episode;
  final String? overview;

  /// Spoken/original language (ISO-639-1) from TMDB — the language we fetch source
  /// subtitles in and declare to the translator.
  final String? originalLanguage;
  final double? voteAverage;
  final String? posterPath; // TMDB path
  final String? posterFile; // local cached absolute path
  final int? dominantColor; // ARGB
  final int? accentColor; // ARGB

  /// Cast/crew name → gender ("m"/"f") from TMDB credits, fed to the translator so
  /// speaker/addressee inflection is deterministic for named people.
  final Map<String, String> characters;

  /// Rich cast list (billing-ordered) for the Characters view: role, actor, photo,
  /// person link, episode count. Derived from the same TMDB credits fetch.
  final List<CastMember> cast;
  final double confidence;
  final int fetchedAtMs;

  /// True once we've queried TMDB for this path (even if nothing matched), so the
  /// background sweep doesn't re-query it every tick.
  final bool searched;

  bool get hasMatch => tmdbId != null;
  bool get isTv => mediaType == 'tv';
  bool get lowConfidence => hasMatch && confidence < 0.6;

  Color? get dominant => dominantColor == null ? null : Color(dominantColor!);
  Color? get accent => accentColor == null ? null : Color(accentColor!);

  /// The "year · S2·E4"-style metadata line for cards/detail.
  String? get metaLine {
    final parts = <String>[];
    if (year != null) parts.add('$year');
    if (season != null && episode != null) {
      parts.add('S$season·E$episode');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  TitleMetadata copyWith({
    int? tmdbId,
    String? mediaType,
    String? name,
    int? year,
    int? season,
    int? episode,
    String? overview,
    double? voteAverage,
    String? originalLanguage,
    String? posterPath,
    String? posterFile,
    int? dominantColor,
    int? accentColor,
    Map<String, String>? characters,
    List<CastMember>? cast,
    double? confidence,
    int? fetchedAtMs,
    bool? searched,
  }) =>
      TitleMetadata(
        path: path,
        tmdbId: tmdbId ?? this.tmdbId,
        mediaType: mediaType ?? this.mediaType,
        name: name ?? this.name,
        year: year ?? this.year,
        season: season ?? this.season,
        episode: episode ?? this.episode,
        overview: overview ?? this.overview,
        voteAverage: voteAverage ?? this.voteAverage,
        originalLanguage: originalLanguage ?? this.originalLanguage,
        posterPath: posterPath ?? this.posterPath,
        posterFile: posterFile ?? this.posterFile,
        dominantColor: dominantColor ?? this.dominantColor,
        accentColor: accentColor ?? this.accentColor,
        characters: characters ?? this.characters,
        cast: cast ?? this.cast,
        confidence: confidence ?? this.confidence,
        fetchedAtMs: fetchedAtMs ?? this.fetchedAtMs,
        searched: searched ?? this.searched,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'tmdb_id': tmdbId,
        'media_type': mediaType,
        'name': name,
        'year': year,
        'season': season,
        'episode': episode,
        'overview': overview,
        'vote_average': voteAverage,
        'original_language': originalLanguage,
        'poster_path': posterPath,
        'poster_file': posterFile,
        'dominant_color': dominantColor,
        'accent_color': accentColor,
        'characters': characters,
        'cast': cast.map((c) => c.toJson()).toList(),
        'confidence': confidence,
        'fetched_at_ms': fetchedAtMs,
        'searched': searched,
      };

  factory TitleMetadata.fromJson(Map<String, dynamic> j) => TitleMetadata(
        path: j['path'] as String,
        tmdbId: (j['tmdb_id'] as num?)?.toInt(),
        mediaType: j['media_type'] as String?,
        name: j['name'] as String?,
        year: (j['year'] as num?)?.toInt(),
        season: (j['season'] as num?)?.toInt(),
        episode: (j['episode'] as num?)?.toInt(),
        overview: j['overview'] as String?,
        voteAverage: (j['vote_average'] as num?)?.toDouble(),
        originalLanguage: j['original_language'] as String?,
        posterPath: j['poster_path'] as String?,
        posterFile: j['poster_file'] as String?,
        dominantColor: (j['dominant_color'] as num?)?.toInt(),
        accentColor: (j['accent_color'] as num?)?.toInt(),
        characters: (j['characters'] as Map?)?.map(
                (k, v) => MapEntry(k as String, v as String)) ??
            const {},
        cast: (j['cast'] as List?)
                ?.map((e) => CastMember.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        fetchedAtMs: (j['fetched_at_ms'] as num?)?.toInt() ?? 0,
        searched: (j['searched'] as bool?) ?? false,
      );
}
