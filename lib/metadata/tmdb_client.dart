// TmdbClient — fetch official title metadata + poster art from TMDB (SPEC §: TMDB
// metadata). Network is named plainly to the user (principle P4). Supports both a
// v3 API key (?api_key=) and a v4 read access token (Bearer) — auto-detected.
//
// Posters are official production artwork from TMDB, which is exactly the "genuine,
// official" representation the library needs.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cast_member.dart';
import 'filename_parser.dart';

const String _apiBase = 'https://api.themoviedb.org/3';
const String _imageBase = 'https://image.tmdb.org/t/p';

/// One TMDB search result / matched title.
class TmdbResult {
  const TmdbResult({
    required this.id,
    required this.mediaType, // 'movie' | 'tv'
    required this.name,
    this.year,
    this.posterPath,
    this.overview,
    this.voteAverage,
    this.originalLanguage,
    this.confidence = 0,
  });

  final int id;
  final String mediaType;
  final String name;
  final int? year;
  final String? posterPath;
  final String? overview;
  final double? voteAverage;

  /// ISO-639-1 language the title was originally produced in (TMDB
  /// `original_language`) — the spoken language we want subtitles in.
  final String? originalLanguage;

  /// 0..1 — how well this result matches the parsed filename.
  final double confidence;

  bool get isTv => mediaType == 'tv';

  /// Full poster URL at [size] (e.g. 'w500', 'w342', 'original').
  String? posterUrl([String size = 'w500']) =>
      posterPath == null ? null : '$_imageBase/$size$posterPath';

  TmdbResult withConfidence(double c) => TmdbResult(
        id: id,
        mediaType: mediaType,
        name: name,
        year: year,
        posterPath: posterPath,
        overview: overview,
        voteAverage: voteAverage,
        originalLanguage: originalLanguage,
        confidence: c,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'media_type': mediaType,
        'name': name,
        'year': year,
        'poster_path': posterPath,
        'overview': overview,
        'vote_average': voteAverage,
        'original_language': originalLanguage,
        'confidence': confidence,
      };

  factory TmdbResult.fromJson(Map<String, dynamic> j) => TmdbResult(
        id: (j['id'] as num).toInt(),
        mediaType: j['media_type'] as String,
        name: j['name'] as String,
        year: (j['year'] as num?)?.toInt(),
        posterPath: j['poster_path'] as String?,
        overview: j['overview'] as String?,
        voteAverage: (j['vote_average'] as num?)?.toDouble(),
        originalLanguage: j['original_language'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
      );
}

class TmdbClient {
  TmdbClient({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 8);

  bool get hasKey => apiKey.trim().isNotEmpty;

  /// v4 read tokens are JWTs ("eyJ…"); anything else is treated as a v3 key.
  bool get _isBearer => apiKey.startsWith('eyJ');

  Uri _u(String path, Map<String, String> query) {
    final q = {if (!_isBearer) 'api_key': apiKey, ...query};
    return Uri.parse('$_apiBase$path').replace(queryParameters: q);
  }

  Map<String, String> get _headers =>
      _isBearer ? {'Authorization': 'Bearer $apiKey'} : const {};

  /// Search TMDB and return ranked candidates (best first) for a parsed name.
  Future<List<TmdbResult>> search(ParsedName parsed) async {
    if (!hasKey) return const [];
    // Series → search/tv (year-filtered); otherwise multi so movies + shows both
    // surface and the caller can pick by confidence.
    final results = parsed.isSeries
        ? await _searchTv(parsed.title, parsed.year)
        : await _searchMulti(parsed.title, parsed.year);
    final ranked = results
        .map((r) => r.withConfidence(_score(r, parsed)))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return ranked;
  }

  /// Best match for [parsed], or null if nothing plausible was found.
  Future<TmdbResult?> bestMatch(ParsedName parsed) async {
    final ranked = await search(parsed);
    return ranked.isEmpty ? null : ranked.first;
  }

  Future<List<TmdbResult>> _searchMulti(String query, int? year) async {
    final r = await _client
        .get(_u('/search/multi', {'query': query, 'include_adult': 'false'}),
            headers: _headers)
        .timeout(_timeout);
    if (r.statusCode != 200) return const [];
    final list = (jsonDecode(r.body)['results'] as List? ?? const []);
    final out = <TmdbResult>[];
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final mt = m['media_type'] as String?;
      if (mt != 'movie' && mt != 'tv') continue;
      out.add(_parse(m, mt!));
    }
    return out;
  }

  Future<List<TmdbResult>> _searchTv(String query, int? year) async {
    final r = await _client
        .get(
            _u('/search/tv', {
              'query': query,
              if (year != null) 'first_air_date_year': '$year',
            }),
            headers: _headers)
        .timeout(_timeout);
    if (r.statusCode != 200) return const [];
    final list = (jsonDecode(r.body)['results'] as List? ?? const []);
    return [for (final e in list) _parse(e as Map<String, dynamic>, 'tv')];
  }

  TmdbResult _parse(Map<String, dynamic> m, String mediaType) {
    final isTv = mediaType == 'tv';
    final name = (isTv ? m['name'] : m['title']) as String? ?? '';
    final date = (isTv ? m['first_air_date'] : m['release_date']) as String?;
    final year = (date != null && date.length >= 4)
        ? int.tryParse(date.substring(0, 4))
        : null;
    return TmdbResult(
      id: (m['id'] as num).toInt(),
      mediaType: mediaType,
      name: name,
      year: year,
      posterPath: m['poster_path'] as String?,
      overview: m['overview'] as String?,
      voteAverage: (m['vote_average'] as num?)?.toDouble(),
      originalLanguage: m['original_language'] as String?,
    );
  }

  /// Profile/portrait URL for a TMDB person `profile_path`, or null.
  static String? profileUrl(String? path, [String size = 'w185']) =>
      path == null ? null : '$_imageBase/$size$path';

  /// Fetch credits ONCE and return BOTH the rich cast list (for the Characters view)
  /// and the name→gender map (for the translator glossary). Empty on any failure.
  Future<({List<CastMember> cast, Map<String, String> genders})> castAndGenders(
      int id, String mediaType) async {
    const empty = (cast: <CastMember>[], genders: <String, String>{});
    if (!hasKey) return empty;
    final isTv = mediaType == 'tv';
    final path = isTv ? '/tv/$id/aggregate_credits' : '/movie/$id/credits';
    try {
      final r = await _client.get(_u(path, const {}), headers: _headers).timeout(_timeout);
      if (r.statusCode != 200) return empty;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (cast: parseCast(j), genders: parseCredits(j));
    } catch (_) {
      return empty;
    }
  }

  /// The portraying actor's biography (the closest TMDB has to a "part summary"),
  /// fetched lazily when a character card is opened. Null on any failure.
  Future<String?> personBio(int personId) async {
    if (!hasKey) return null;
    try {
      final r = await _client
          .get(_u('/person/$personId', const {}), headers: _headers)
          .timeout(_timeout);
      if (r.statusCode != 200) return null;
      final bio = (jsonDecode(r.body)['biography'] as String?)?.trim();
      return (bio == null || bio.isEmpty) ? null : bio;
    } catch (_) {
      return null;
    }
  }

  /// Parse credits into the rich cast list (billing-ordered), capped to [maxEntries].
  static List<CastMember> parseCast(Map<String, dynamic> j, {int maxEntries = 40}) {
    String g(Object? v) => v == 1 ? 'f' : (v == 2 ? 'm' : '');
    final out = <CastMember>[];
    for (final c in (j['cast'] as List? ?? const [])) {
      final m = c as Map<String, dynamic>;
      final id = (m['id'] as num?)?.toInt();
      final actor = (m['name'] as String?)?.trim();
      if (id == null || actor == null || actor.isEmpty) continue;
      String? character = (m['character'] as String?)?.trim(); // movie shape
      final roles = m['roles'] as List?; // tv aggregate shape
      if ((character == null || character.isEmpty) && roles != null && roles.isNotEmpty) {
        character = ((roles.first as Map)['character'] as String?)?.trim();
      }
      out.add(CastMember(
        personId: id,
        actor: actor,
        character: character,
        gender: g(m['gender']),
        order: (m['order'] as num?)?.toInt() ?? 9999,
        profilePath: m['profile_path'] as String?,
        episodeCount: (m['total_episode_count'] as num?)?.toInt(),
        popularity: (m['popularity'] as num?)?.toDouble(),
      ));
    }
    out.sort((a, b) => a.order.compareTo(b.order));
    return out.length > maxEntries ? out.sublist(0, maxEntries) : out;
  }

  /// Parse a TMDB credits payload (movie `/credits` or tv `/aggregate_credits`) into a
  /// name→gender map, capped to [maxEntries] (cast is billing-ordered, most likely to be
  /// named on screen). TMDB gender: 1=female, 2=male; others are skipped.
  static Map<String, String> parseCredits(Map<String, dynamic> j, {int maxEntries = 40}) {
    final out = <String, String>{};
    String? g(Object? v) => v == 1 ? 'f' : (v == 2 ? 'm' : null);
    void add(Object? name, String? gender) {
      if (gender == null) return;
      final n = (name as String?)?.trim();
      if (n == null || n.length < 2) return;
      if (out.length >= maxEntries && !out.containsKey(n)) return;
      out.putIfAbsent(n, () => gender);
    }

    // Key crew FIRST (small set, high-value): director/writer cameos are exactly the
    // names broken-fourth-wall lines address (e.g. "…, Mel Brooks!") and would
    // otherwise be starved by a large cast list under the cap.
    const wantedJobs = {'Director', 'Writer', 'Screenplay', 'Story'};
    for (final c in (j['crew'] as List? ?? const [])) {
      final m = c as Map<String, dynamic>;
      if (!wantedJobs.contains(m['job'] as String? ?? '')) continue;
      add(m['name'], g(m['gender']));
    }
    for (final c in (j['cast'] as List? ?? const [])) {
      if (out.length >= maxEntries) break;
      final m = c as Map<String, dynamic>;
      final gen = g(m['gender']);
      add(m['name'], gen);
      add(m['character'], gen); // movie shape
      for (final role in (m['roles'] as List? ?? const [])) {
        add((role as Map<String, dynamic>)['character'], gen); // tv aggregate shape
      }
    }
    return out;
  }

  /// Confidence: title similarity (primary) nudged by year match + popularity.
  double _score(TmdbResult r, ParsedName parsed) {
    final sim = _titleSimilarity(
        parsed.title.toLowerCase(), r.name.toLowerCase());
    var score = sim;
    if (parsed.year != null && r.year != null) {
      final diff = (parsed.year! - r.year!).abs();
      if (diff == 0) {
        score += 0.1;
      } else if (diff <= 1) {
        score += 0.03;
      } else {
        score -= 0.05;
      }
    }
    if (r.posterPath != null) score += 0.03; // prefer results with art
    return score.clamp(0.0, 1.0);
  }

  void close() => _client.close();
}

/// Token-overlap similarity (Sørensen–Dice over word sets), with an exact-match
/// and prefix boost — cheap and robust for short title strings.
double _titleSimilarity(String a, String b) {
  if (a == b) return 1.0;
  final wa = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
  final wb = b.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
  if (wa.isEmpty || wb.isEmpty) return 0;
  final inter = wa.intersection(wb).length;
  final dice = (2.0 * inter) / (wa.length + wb.length);
  // Boost when one title starts with the other (e.g. "Foundation" vs
  // "Foundation and Empire").
  final prefix = (b.startsWith(a) || a.startsWith(b)) ? 0.15 : 0.0;
  return (dice + prefix).clamp(0.0, 1.0);
}
