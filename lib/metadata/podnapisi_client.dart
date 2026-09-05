import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'subtitle_source.dart';

const String _podnapisiBase = 'https://www.podnapisi.net';

class PodnapisiClient implements SourceSubtitleProvider {
  PodnapisiClient({
    http.Client? client,
    String userAgent = 'AutoSubMediaPlayer/0.1',
  }) : _client = client ?? http.Client(),
       _userAgent = userAgent;

  final http.Client _client;
  final String _userAgent;
  static const Duration _timeout = Duration(seconds: 12);

  @override
  String get id => 'podnapisi';

  @override
  String get name => 'Podnapisi';

  @override
  bool get enabled => true;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'User-Agent': _userAgent,
  };

  @override
  Future<List<SourceSubtitleCandidate>> search(
    SourceSubtitleQuery query,
  ) async {
    final params = <String, String>{
      'keywords': _keywords(query),
      'language': query.language,
    };
    if (query.season != null) params['seasons'] = '${query.season}';
    if (query.episode != null) params['episodes'] = '${query.episode}';
    if (query.year != null) params['year'] = '${query.year}';

    final uri = Uri.parse(
      '$_podnapisiBase/subtitles/search/advanced',
    ).replace(queryParameters: params);
    final r = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (r.statusCode != 200 || r.body.trim().isEmpty) return const [];

    final decoded = jsonDecode(r.body);
    final rows = _rows(decoded);
    final out = <SourceSubtitleCandidate>[];
    for (final row in rows) {
      final c = _candidate(row, query);
      if (c != null) out.add(c);
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  @override
  Future<Uint8List?> download(SourceSubtitleCandidate candidate) async {
    final uri = candidate.downloadUri;
    if (uri == null) return null;
    final r = await _client
        .get(
          uri,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/octet-stream,*/*',
          },
        )
        .timeout(_timeout);
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
    return r.bodyBytes;
  }

  String _keywords(SourceSubtitleQuery query) {
    final q = query.query?.trim();
    if (q != null && q.isNotEmpty) return q;
    return p.basenameWithoutExtension(query.videoPath).replaceAll('.', ' ');
  }

  List<Map<String, dynamic>> _rows(Object? decoded) {
    if (decoded is List) {
      return decoded.whereType<Map>().map(_stringMap).toList();
    }
    if (decoded is! Map) return const [];
    final root = _stringMap(decoded);
    for (final key in const ['data', 'subtitles', 'results', 'items']) {
      final value = root[key];
      if (value is List) {
        return value.whereType<Map>().map(_stringMap).toList();
      }
    }
    return const [];
  }

  SourceSubtitleCandidate? _candidate(
    Map<String, dynamic> row,
    SourceSubtitleQuery query,
  ) {
    final attrs = row['attributes'] is Map
        ? _stringMap(row['attributes'] as Map)
        : row;
    final lang =
        (_firstString(attrs, const ['language', 'lang']) ??
                _firstString(row, const ['language', 'lang']) ??
                query.language)
            .toLowerCase();
    if (!lang.startsWith(query.language)) return null;

    final downloadUri = _downloadUri(row, attrs);
    if (downloadUri == null) return null;

    final release =
        _firstString(attrs, const [
          'release',
          'release_name',
          'filename',
          'file_name',
          'title',
        ]) ??
        _firstString(row, const ['release', 'title', 'name']);
    final downloads = _firstInt(attrs, const ['downloads', 'download_count']);
    final rating = _firstDouble(attrs, const ['rating', 'ratings']);

    var score = 12.0;
    final normalizedRelease = _compact(release ?? '');
    final normalizedFile = _compact(
      p.basenameWithoutExtension(query.videoPath),
    );
    if (normalizedRelease.isNotEmpty &&
        normalizedFile.isNotEmpty &&
        (normalizedFile.contains(normalizedRelease) ||
            normalizedRelease.contains(normalizedFile))) {
      score += 35;
    }
    if (query.season != null &&
        _firstInt(attrs, const ['season', 'season_number']) == query.season) {
      score += 8;
    }
    if (query.episode != null &&
        _firstInt(attrs, const ['episode', 'episode_number']) ==
            query.episode) {
      score += 8;
    }
    if (query.year != null && _firstInt(attrs, const ['year']) == query.year) {
      score += 4;
    }
    if (downloads != null && downloads > 0) {
      score += (downloads > 100000 ? 100000 : downloads) / 10000;
    }
    if (rating != null) score += rating;

    return SourceSubtitleCandidate(
      providerId: id,
      providerName: name,
      language: lang,
      score: score,
      releaseName: release,
      downloadUri: downloadUri,
      downloads: downloads,
    );
  }

  Uri? _downloadUri(Map<String, dynamic> row, Map<String, dynamic> attrs) {
    for (final source in [attrs, row]) {
      final direct = _firstString(source, const [
        'download',
        'download_url',
        'downloadUrl',
        'download_link',
      ]);
      final uri = _uriFromString(direct);
      if (uri != null) return uri;
    }

    final url = _uriFromString(
      _firstString(attrs, const ['url', 'link']) ??
          _firstString(row, const ['url', 'link']),
    );
    if (url != null && url.path.contains('/subtitles/')) {
      final path = url.path.endsWith('/download')
          ? url.path
          : '${url.path.replaceFirst(RegExp(r"/$"), '')}/download';
      return url.replace(path: path);
    }

    final idValue =
        _firstString(row, const ['id']) ??
        _firstString(attrs, const ['id', 'pid']);
    if (idValue != null && idValue.isNotEmpty) {
      return Uri.parse('$_podnapisiBase/subtitles/$idValue/download');
    }
    return null;
  }

  Uri? _uriFromString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.hasScheme) return uri;
    if (raw.startsWith('/')) return Uri.parse('$_podnapisiBase$raw');
    return null;
  }

  String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return '$value';
    }
    return null;
  }

  int? _firstInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
    }
    return null;
  }

  double? _firstDouble(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value);
    }
    return null;
  }

  String _compact(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Map<String, dynamic> _stringMap(Map map) =>
      map.map((key, value) => MapEntry('$key', value));

  void close() => _client.close();
}
