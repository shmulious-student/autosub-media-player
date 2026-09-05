// OpenSubtitlesClient — keyed provider for ORIGINAL-language subtitle candidates.
// SubtitleSourceResolver ranks its results against keyless providers and writes the
// chosen source sidecar for the engine.
//
// Provider: OpenSubtitles REST API (https://api.opensubtitles.com). Needs the user's
// free API key (Settings). Note: these are third-party, user-uploaded copyrighted
// files — used here only as INPUT to a derived translation; be deliberate about ToS
// for a commercial release.
//
// "Most accurate" = rank candidates: exact file (moviehash) match first, then human
// (not machine/AI-translated) subs, trusted uploaders, and download count.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'subtitle_source.dart';

const String _apiBase = 'https://api.opensubtitles.com/api/v1';

class OpenSubtitlesClient implements SourceSubtitleProvider {
  OpenSubtitlesClient({
    required this.apiKey,
    http.Client? client,
    String userAgent = 'AutoSubMediaPlayer/0.1',
  }) : _client = client ?? http.Client(),
       _userAgent = userAgent;

  /// Live getter so a key entered in Settings takes effect without restart.
  final String Function() apiKey;
  final http.Client _client;
  final String _userAgent;
  static const Duration _timeout = Duration(seconds: 12);

  String get _key => apiKey().trim();
  @override
  String get id => 'opensubtitles';

  @override
  String get name => 'OpenSubtitles';

  @override
  bool get enabled => hasKey;

  bool get hasKey => _key.isNotEmpty;

  Map<String, String> get _headers => {
    'Api-Key': _key,
    'User-Agent': _userAgent,
    'Accept': 'application/json',
  };

  /// Fetch + save the best original-language subtitle for [videoPath]. Returns the
  /// saved sidecar path, or null if there's no key / no match / quota hit / any error
  /// (caller then falls through to ASR). Idempotent: a cached sidecar is reused.
  Future<String?> fetchSourceSubtitle({
    required String videoPath,
    required String originalLanguage,
    int? tmdbId,
    int? season,
    int? episode,
    int? year,
    String? query,
  }) async {
    try {
      final lang = SourceSubtitleCache.normalizeLang(originalLanguage);
      final cached = SourceSubtitleCache.read(videoPath: videoPath, lang: lang);
      if (cached != null) return cached.path; // cache hit
      if (!hasKey) return null;

      final candidates = await search(
        SourceSubtitleQuery(
          videoPath: videoPath,
          originalLanguage: lang,
          tmdbId: tmdbId,
          season: season,
          episode: episode,
          year: year,
          query: query,
        ),
      );
      if (candidates.isEmpty) return null;
      candidates.sort((a, b) => b.score.compareTo(a.score));
      for (final candidate in candidates) {
        final bytes = await download(candidate);
        if (bytes == null || bytes.isEmpty) continue;
        final payload = SourceSubtitleCache.unpackPayload(
          bytes,
          fileName: candidate.releaseName,
        );
        if (payload == null) continue;
        return SourceSubtitleCache.writePayload(
          videoPath: videoPath,
          lang: lang,
          payload: payload,
          providerId: id,
          providerName: name,
          releaseName: candidate.releaseName,
          sourceUrl: candidate.downloadUri?.toString(),
          score: candidate.score,
        ).path;
      }
      return null;
    } catch (_) {
      return null; // any failure → ASR fallback
    }
  }

  // MARK: - Search + rank

  @override
  Future<List<SourceSubtitleCandidate>> search(
    SourceSubtitleQuery query,
  ) async {
    if (!hasKey) return const [];
    final lang = query.language;
    final params = <String, String>{
      'languages': lang,
      'order_by': 'download_count',
    };
    if (query.tmdbId != null) params['tmdb_id'] = '${query.tmdbId}';
    if (query.season != null) params['season_number'] = '${query.season}';
    if (query.episode != null) params['episode_number'] = '${query.episode}';
    if (query.year != null && query.tmdbId == null) {
      params['year'] = '${query.year}';
    }
    if (query.query != null &&
        query.query!.trim().isNotEmpty &&
        query.tmdbId == null) {
      params['query'] = query.query!.trim();
    }
    final hash = await _movieHash(query.videoPath);
    if (hash != null) params['moviehash'] = hash;

    // Need at least one selector beyond language to get sensible results.
    if (query.tmdbId == null &&
        (query.query == null || query.query!.trim().isEmpty) &&
        hash == null) {
      return const [];
    }

    final uri = Uri.parse(
      '$_apiBase/subtitles',
    ).replace(queryParameters: params);
    final r = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) return const [];
    final data = (jsonDecode(r.body)['data'] as List? ?? const []);
    final candidates = <SourceSubtitleCandidate>[];
    for (final e in data) {
      final c = _OsCandidate.tryParse(
        e as Map<String, dynamic>,
        providerId: id,
        providerName: name,
        wantLang: lang,
      );
      if (c != null) candidates.add(c);
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }

  @override
  Future<Uint8List?> download(SourceSubtitleCandidate candidate) async {
    final fileId = candidate.fileId;
    if (fileId == null) return null;
    final url = await _downloadLink(fileId);
    if (url == null) return null;

    final r = await _client.get(Uri.parse(url)).timeout(_timeout);
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
    return r.bodyBytes;
  }

  Future<String?> _downloadLink(int fileId) async {
    final r = await _client
        .post(
          Uri.parse('$_apiBase/download'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'file_id': fileId}),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) return null; // 406 ⇒ daily quota exhausted
    return jsonDecode(r.body)['link'] as String?;
  }

  // MARK: - Helpers

  /// OpenSubtitles / OSDb hash: 64-bit sum of the file size and every uint64 word in
  /// the first and last 64 KiB. Returns null for files too small or unreadable.
  Future<String?> _movieHash(String path) async {
    const chunk = 64 * 1024;
    try {
      final file = File(path);
      final size = await file.length();
      if (size < chunk) return null;
      final raf = await file.open();
      try {
        int hash = size;
        hash = _addChunkHash(hash, await _readAt(raf, 0, chunk));
        hash = _addChunkHash(hash, await _readAt(raf, size - chunk, chunk));
        return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _readAt(
    RandomAccessFile raf,
    int offset,
    int length,
  ) async {
    await raf.setPosition(offset);
    return raf.read(length);
  }

  int _addChunkHash(int hash, Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    var h = hash;
    for (var i = 0; i + 8 <= bytes.length; i += 8) {
      h += bd.getUint64(i, Endian.little);
    }
    return h;
  }

  void close() => _client.close();
}

/// One ranked OpenSubtitles candidate (the best file within a subtitle entry).
class _OsCandidate {
  static SourceSubtitleCandidate? tryParse(
    Map<String, dynamic> e, {
    required String providerId,
    required String providerName,
    required String wantLang,
  }) {
    final a = e['attributes'] as Map<String, dynamic>?;
    if (a == null) return null;
    final lang = (a['language'] as String?)?.toLowerCase();
    if (lang != null && wantLang.isNotEmpty && !lang.startsWith(wantLang)) {
      return null;
    }

    final files = (a['files'] as List? ?? const []);
    if (files.isEmpty) return null;
    final firstFile = files.first as Map<String, dynamic>;
    final fileId = (firstFile['file_id'] as num?)?.toInt();
    if (fileId == null) return null;

    // Score: a faithful, human, trusted, popular, exact-file match ranks highest.
    var score = 0.0;
    if (a['moviehash_match'] == true) score += 100;
    if (a['ai_translated'] != true) score += 20;
    if (a['machine_translated'] != true) score += 20;
    if (a['from_trusted'] == true) score += 10;
    if (a['hearing_impaired'] == true) {
      score -= 5; // [sound] captions we'd strip
    }
    final downloads = (a['download_count'] as num?)?.toDouble() ?? 0;
    score +=
        (downloads > 0 ? (1 + downloads).clamp(1, 1e9) : 1) /
        1e6; // tiny tiebreak
    final ratings = (a['ratings'] as num?)?.toDouble() ?? 0;
    score += ratings * 0.1;

    return SourceSubtitleCandidate(
      providerId: providerId,
      providerName: providerName,
      language: lang ?? wantLang,
      score: score,
      releaseName:
          (firstFile['file_name'] as String?) ?? (a['release'] as String?),
      fileId: fileId,
      downloads: (a['download_count'] as num?)?.toInt(),
      trusted: a['from_trusted'] == true,
      machineTranslated:
          a['machine_translated'] == true || a['ai_translated'] == true,
      hearingImpaired: a['hearing_impaired'] == true,
    );
  }
}
