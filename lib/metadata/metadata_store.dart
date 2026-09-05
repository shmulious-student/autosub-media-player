// MetadataStore — fetches + caches TMDB metadata and official posters for every
// library title, and extracts each poster's color palette (which tints the title's
// detail page). Local-first: posters are cached on disk, metadata persisted as JSON;
// TMDB is the only network call and it's named to the user (principle P4).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'package:path/path.dart' as p;

import '../common/app_paths.dart';
import 'filename_parser.dart';
import 'title_metadata.dart';
import 'tmdb_client.dart';

/// Minimum confidence to auto-accept a TMDB match (below this we still keep the
/// best guess but flag it low-confidence so the UI can offer "Fix match").
const double _acceptThreshold = 0.3;

class MetadataStore extends ChangeNotifier {
  MetadataStore({required this.apiKey, TmdbClient? client})
      : _client = client {
    _injectedClient = client != null;
  }

  /// Live read of the user's TMDB API key (from Settings), so pasting it later
  /// immediately enables enrichment without a restart.
  final String Function() apiKey;

  TmdbClient? _client;
  bool _injectedClient = false;
  String _clientKey = '';

  final Map<String, TitleMetadata> _byPath = {};
  final Set<String> _fetching = {};
  /// In-flight enrichment per path, so concurrent callers coalesce + await it.
  final Map<String, Future<void>> _inflight = {};
  Directory? _posterDir;
  File? _storeFile;
  bool _sweeping = false;

  /// Number of titles currently being fetched (drives "Searching TMDB…").
  int get fetchingCount => _fetching.length;
  bool get hasApiKey => apiKey().trim().isNotEmpty;

  TitleMetadata? metadataFor(String path) => _byPath[path];

  /// Backfill the cast/crew gender map for an already-matched title that predates the
  /// credits feature (or was enriched before it). Returns the map (possibly cached).
  /// No-op without a key / match; never throws.
  Future<Map<String, String>> ensureCredits(String path, {bool force = false}) async {
    final m = _byPath[path];
    if (m == null || !m.hasMatch || m.tmdbId == null) return const {};
    // Re-fetch if forced, or if EITHER the gender map or the rich cast is missing
    // (titles enriched before the cast feature have the map but no cast list).
    if (!force && m.characters.isNotEmpty && m.cast.isNotEmpty) return m.characters;
    if (!hasApiKey) return const {};
    try {
      final res = await _resolveClient()
          .castAndGenders(m.tmdbId!, m.mediaType ?? 'movie');
      if (res.genders.isNotEmpty || res.cast.isNotEmpty || force) {
        _byPath[path] = m.copyWith(characters: res.genders, cast: res.cast);
        await _save();
        notifyListeners();
      }
      return res.genders;
    } catch (_) {
      return const {};
    }
  }

  /// The portraying actor's biography (lazy, when a character card is opened).
  Future<String?> personBio(int personId) async {
    if (!hasApiKey) return null;
    return _resolveClient().personBio(personId);
  }

  /// Persist AI-generated "role in the plot" summaries (character name → sentence)
  /// onto this title's cast. Matches by character name (TV roles[].character or the
  /// movie character field). No-op if nothing matches.
  Future<void> setCharacterSummaries(
      String path, Map<String, String> byCharacter) async {
    final m = _byPath[path];
    if (m == null || m.cast.isEmpty || byCharacter.isEmpty) return;
    var changed = false;
    final updated = m.cast.map((c) {
      final s = byCharacter[c.displayCharacter] ?? byCharacter[c.character ?? ''];
      if (s != null && s.isNotEmpty && s != c.roleSummary) {
        changed = true;
        return c.withSummary(s);
      }
      return c;
    }).toList();
    if (!changed) return;
    _byPath[path] = m.copyWith(cast: updated);
    await _save();
    notifyListeners();
  }

  /// Re-pull EVERYTHING for a title from TMDB: re-match (poster, name, year,
  /// original language) and re-fetch the cast/crew gender map. Used by the "Refetch
  /// metadata" actions (film / series / season / episode).
  Future<void> refetch(String path) async {
    await enrich(path, force: true);
    await ensureCredits(path, force: true);
  }

  /// Refetch metadata for many paths (a whole series or season) sequentially, so
  /// we don't hammer TMDB. Errors per-path are swallowed by [refetch].
  Future<void> refetchAll(Iterable<String> paths) async {
    for (final path in paths) {
      await refetch(path);
    }
  }

  TmdbClient _resolveClient() {
    final key = apiKey();
    if (_injectedClient) return _client!;
    if (_client == null || _clientKey != key) {
      _client?.close();
      _client = TmdbClient(apiKey: key);
      _clientKey = key;
    }
    return _client!;
  }

  // --- Persistence --------------------------------------------------------

  Future<File> _file() async {
    if (_storeFile != null) return _storeFile!;
    return _storeFile = AutoSubPaths.metadataFile();
  }

  Future<Directory> _posters() async {
    if (_posterDir != null) return _posterDir!;
    return _posterDir = AutoSubPaths.postersDir();
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      for (final e in list) {
        final m = TitleMetadata.fromJson(e as Map<String, dynamic>);
        _byPath[m.path] = m;
      }
      notifyListeners();
    } catch (_) {
      // Corrupt cache → start empty.
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(
          jsonEncode(_byPath.values.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  // --- Enrichment ---------------------------------------------------------

  /// Enrich a single path (skips if already matched, unless [force]).
  Future<void> enrich(String path, {bool force = false}) async {
    if (!hasApiKey) return;
    final existing = _byPath[path];
    if (!force && existing != null && (existing.hasMatch || existing.searched)) {
      return;
    }
    // Coalesce concurrent enrich of the same path: callers that need the result
    // (source-subtitle + credits at enqueue time) must AWAIT the in-flight fetch,
    // not race past it and see an unmatched title (→ no characters / no source).
    final pending = _inflight[path];
    if (pending != null) return pending;
    final completer = Completer<void>();
    _inflight[path] = completer.future;
    _fetching.add(path);
    notifyListeners();
    try {
      final parsed = parseFilename(path);
      final best = await _resolveClient().bestMatch(parsed);
      if (best == null || best.confidence < _acceptThreshold) {
        _byPath[path] = (existing ?? TitleMetadata(path: path)).copyWith(
          searched: true,
          fetchedAtMs: _nowMs(),
        );
      } else {
        final posterFile = await _cachePoster(best);
        final colors = posterFile == null
            ? (dominant: null, accent: null)
            : await _extractPalette(posterFile);
        _byPath[path] = TitleMetadata(
          path: path,
          tmdbId: best.id,
          mediaType: best.mediaType,
          name: best.name,
          year: best.year,
          season: parsed.season,
          episode: parsed.episode,
          overview: best.overview,
          voteAverage: best.voteAverage,
          originalLanguage: best.originalLanguage,
          posterPath: best.posterPath,
          posterFile: posterFile,
          dominantColor: colors.dominant,
          accentColor: colors.accent,
          // Credits (gender map) are fetched LAZILY via ensureCredits() at translate
          // time — keep enrichment fast (one network call, not two) so posters/grouping
          // fill in quickly.
          confidence: best.confidence,
          fetchedAtMs: _nowMs(),
          searched: true,
        );
      }
      await _save();
    } catch (_) {
      // Network/parse hiccup — leave unsearched so a later sweep retries.
    } finally {
      _fetching.remove(path);
      _inflight.remove(path);
      if (!completer.isCompleted) completer.complete();
      notifyListeners();
    }
  }

  /// Free-text TMDB search for the "Fix match" flow (names the network call to the
  /// caller's UI). Returns ranked candidates, best first.
  Future<List<TmdbResult>> search(String query) async {
    if (!hasApiKey || query.trim().isEmpty) return const [];
    return _resolveClient().search(ParsedName(title: query.trim()));
  }

  /// Manually assign a TMDB match (the "Fix match" flow). Re-pulls poster + palette.
  Future<void> assignMatch(String path, TmdbResult result) async {
    _fetching.add(path);
    notifyListeners();
    try {
      final parsed = parseFilename(path);
      final posterFile = await _cachePoster(result);
      final colors = posterFile == null
          ? (dominant: null, accent: null)
          : await _extractPalette(posterFile);
      _byPath[path] = TitleMetadata(
        path: path,
        tmdbId: result.id,
        mediaType: result.mediaType,
        name: result.name,
        year: result.year,
        season: parsed.season,
        episode: parsed.episode,
        overview: result.overview,
        voteAverage: result.voteAverage,
        originalLanguage: result.originalLanguage,
        posterPath: result.posterPath,
        posterFile: posterFile,
        dominantColor: colors.dominant,
        accentColor: colors.accent,
        confidence: 1.0, // user-confirmed
        fetchedAtMs: _nowMs(),
        searched: true,
      );
      await _save();
    } finally {
      _fetching.remove(path);
      notifyListeners();
    }
  }

  /// Background sweep: enrich every path that hasn't been searched yet, one at a
  /// time (polite to the TMDB rate limit).
  Future<void> sweep(Iterable<String> paths) async {
    if (_sweeping || !hasApiKey) return;
    _sweeping = true;
    try {
      for (final path in paths) {
        final m = _byPath[path];
        if (m != null && (m.hasMatch || m.searched)) continue;
        await enrich(path);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      _sweeping = false;
    }
  }

  Future<String?> _cachePoster(TmdbResult result) async {
    final url = result.posterUrl('w500');
    if (url == null) return null;
    try {
      final dir = await _posters();
      final file = File(p.join(dir.path, '${result.id}.jpg'));
      if (file.existsSync() && file.lengthSync() > 0) return file.path;
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      await file.writeAsBytes(resp.bodyBytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<({int? dominant, int? accent})> _extractPalette(
      String posterFile) async {
    try {
      final pal = await PaletteGenerator.fromImageProvider(
        FileImage(File(posterFile)),
        size: const Size(120, 180),
        maximumColorCount: 16,
      );
      final dominant = pal.dominantColor?.color;
      final accent = pal.vibrantColor?.color ??
          pal.lightVibrantColor?.color ??
          pal.mutedColor?.color ??
          dominant;
      return (dominant: dominant?.toARGB32(), accent: accent?.toARGB32());
    } catch (_) {
      return (dominant: null, accent: null);
    }
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Forget a title's metadata (used when a title is removed/library cleared).
  void forget(String path) {
    if (_byPath.remove(path) != null) {
      notifyListeners();
      unawaited(_save());
    }
  }

  void clear() {
    _byPath.clear();
    notifyListeners();
    unawaited(_save());
  }

  /// Full reset: forget all metadata AND delete the on-disk cache (metadata.json +
  /// every cached poster). Used by Settings → "Reset all data".
  Future<void> clearAll() async {
    _byPath.clear();
    notifyListeners();
    try {
      final f = await _file();
      if (f.existsSync()) await f.delete();
      final dir = await _posters();
      if (dir.existsSync()) {
        for (final e in dir.listSync()) {
          try {
            e.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {
      // Best-effort; in-memory state is already cleared.
    }
  }

  @override
  void dispose() {
    if (!_injectedClient) _client?.close();
    super.dispose();
  }
}
