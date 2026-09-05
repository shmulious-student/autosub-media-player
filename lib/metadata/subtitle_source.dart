import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class SourceSubtitleQuery {
  const SourceSubtitleQuery({
    required this.videoPath,
    required this.originalLanguage,
    this.tmdbId,
    this.season,
    this.episode,
    this.year,
    this.query,
  });

  final String videoPath;
  final String originalLanguage;
  final int? tmdbId;
  final int? season;
  final int? episode;
  final int? year;
  final String? query;

  String get language => SourceSubtitleCache.normalizeLang(originalLanguage);
}

class SourceSubtitleCandidate {
  const SourceSubtitleCandidate({
    required this.providerId,
    required this.providerName,
    required this.language,
    required this.score,
    this.releaseName,
    this.downloads,
    this.trusted = false,
    this.machineTranslated = false,
    this.hearingImpaired = false,
    this.downloadUri,
    this.fileId,
    this.payload = const {},
  });

  final String providerId;
  final String providerName;
  final String language;
  final double score;
  final String? releaseName;
  final int? downloads;
  final bool trusted;
  final bool machineTranslated;
  final bool hearingImpaired;
  final Uri? downloadUri;
  final int? fileId;
  final Map<String, Object?> payload;
}

class SourceSubtitleResult {
  const SourceSubtitleResult({
    required this.path,
    required this.language,
    required this.providerId,
    required this.providerName,
    required this.fetchedAtMs,
    this.releaseName,
    this.sourceUrl,
    this.score,
    this.overrideEmbedded = false,
  });

  final String path;
  final String language;
  final String providerId;
  final String providerName;
  final int fetchedAtMs;
  final String? releaseName;
  final String? sourceUrl;
  final double? score;

  /// Manual file/URL swaps must beat embedded subtitles; automatic web fetches
  /// should not.
  final bool overrideEmbedded;

  Map<String, dynamic> toJson() => {
    'path': path,
    'language': language,
    'provider_id': providerId,
    'provider_name': providerName,
    'fetched_at_ms': fetchedAtMs,
    'release_name': releaseName,
    'source_url': sourceUrl,
    'score': score,
    'override_embedded': overrideEmbedded,
  };

  factory SourceSubtitleResult.fromJson(Map<String, dynamic> j) =>
      SourceSubtitleResult(
        path: j['path'] as String,
        language: (j['language'] as String?) ?? 'en',
        providerId: (j['provider_id'] as String?) ?? 'cached',
        providerName: (j['provider_name'] as String?) ?? 'Cached source',
        fetchedAtMs: (j['fetched_at_ms'] as num?)?.toInt() ?? 0,
        releaseName: j['release_name'] as String?,
        sourceUrl: j['source_url'] as String?,
        score: (j['score'] as num?)?.toDouble(),
        overrideEmbedded: (j['override_embedded'] as bool?) ?? false,
      );
}

class SourceSubtitlePayload {
  const SourceSubtitlePayload({
    required this.bytes,
    required this.extension,
    this.fileName,
  });

  final Uint8List bytes;
  final String extension;
  final String? fileName;
}

abstract class SourceSubtitleProvider {
  String get id;
  String get name;
  bool get enabled => true;

  Future<List<SourceSubtitleCandidate>> search(SourceSubtitleQuery query);
  Future<Uint8List?> download(SourceSubtitleCandidate candidate);
}

class SubtitleSourceResolver {
  SubtitleSourceResolver({
    required List<SourceSubtitleProvider> providers,
    http.Client? client,
  }) : _providers = providers,
       _client = client ?? http.Client();

  final List<SourceSubtitleProvider> _providers;
  final http.Client _client;

  Future<SourceSubtitleResult?> fetchBest({
    required SourceSubtitleQuery query,
    bool force = false,
  }) async {
    final lang = query.language;
    final cached = SourceSubtitleCache.read(
      videoPath: query.videoPath,
      lang: lang,
    );
    if (!force && cached != null) return cached;

    final candidates = <_CandidateWithProvider>[];
    for (final provider in _providers.where((p) => p.enabled)) {
      try {
        final found = await provider.search(query);
        candidates.addAll(
          found.map((c) => _CandidateWithProvider(provider, c)),
        );
      } catch (_) {
        // One provider being down must not block ASR fallback.
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.candidate.score.compareTo(a.candidate.score));

    for (final hit in candidates) {
      try {
        final bytes = await hit.provider.download(hit.candidate);
        if (bytes == null || bytes.isEmpty) continue;
        final payload = SourceSubtitleCache.unpackPayload(
          bytes,
          fileName: hit.candidate.releaseName,
        );
        if (payload == null) continue;
        await SourceSubtitleCache.delete(
          videoPath: query.videoPath,
          lang: lang,
        );
        return SourceSubtitleCache.writePayload(
          videoPath: query.videoPath,
          lang: lang,
          payload: payload,
          providerId: hit.provider.id,
          providerName: hit.provider.name,
          releaseName: hit.candidate.releaseName,
          sourceUrl: hit.candidate.downloadUri?.toString(),
          score: hit.candidate.score,
          overrideEmbedded: false,
        );
      } catch (_) {
        // Try the next ranked candidate before giving up.
      }
    }
    return null;
  }

  Future<SourceSubtitleResult?> importUrl({
    required String videoPath,
    required String lang,
    required Uri uri,
  }) async {
    final r = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
    final payload = SourceSubtitleCache.unpackPayload(
      r.bodyBytes,
      fileName: p.basename(uri.path),
    );
    if (payload == null) return null;
    await SourceSubtitleCache.delete(videoPath: videoPath, lang: lang);
    return SourceSubtitleCache.writePayload(
      videoPath: videoPath,
      lang: lang,
      payload: payload,
      providerId: 'manual-url',
      providerName: 'Manual URL',
      releaseName: payload.fileName ?? p.basename(uri.path),
      sourceUrl: uri.toString(),
      overrideEmbedded: true,
    );
  }

  void close() => _client.close();
}

class SourceSubtitleCache {
  static const _extensions = ['srt', 'vtt', 'ass', 'ssa'];
  static const _zipMagic = [0x50, 0x4b, 0x03, 0x04];

  static String normalizeLang(String code) {
    final c = code.trim().toLowerCase();
    if (c.isEmpty || c == 'und' || c == 'xx') return 'en';
    return c.length >= 2 ? c.substring(0, 2) : 'en';
  }

  static SourceSubtitleResult? read({
    required String videoPath,
    required String lang,
  }) {
    final path = existingPath(videoPath: videoPath, lang: lang);
    if (path == null) return null;
    final meta = File(_metaPath(path));
    if (meta.existsSync()) {
      try {
        final decoded =
            jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
        return SourceSubtitleResult.fromJson({...decoded, 'path': path});
      } catch (_) {}
    }
    return SourceSubtitleResult(
      path: path,
      language: normalizeLang(lang),
      providerId: 'cached',
      providerName: 'Cached source',
      fetchedAtMs: 0,
    );
  }

  static String? existingPath({
    required String videoPath,
    required String lang,
  }) {
    for (final ext in _extensions) {
      final path = sidecarPath(
        videoPath: videoPath,
        lang: lang,
        extension: ext,
      );
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return null;
  }

  static String sidecarPath({
    required String videoPath,
    required String lang,
    String extension = 'srt',
  }) {
    final cleanExt = _cleanExtension(extension);
    final dir = p.dirname(videoPath);
    final base = p.basenameWithoutExtension(videoPath);
    return p.join(dir, '$base.${normalizeLang(lang)}.src.$cleanExt');
  }

  static Future<void> delete({
    required String videoPath,
    required String lang,
  }) async {
    for (final ext in _extensions) {
      final path = sidecarPath(
        videoPath: videoPath,
        lang: lang,
        extension: ext,
      );
      for (final f in [File(path), File(_metaPath(path))]) {
        try {
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      }
    }
  }

  static SourceSubtitleResult writePayload({
    required String videoPath,
    required String lang,
    required SourceSubtitlePayload payload,
    required String providerId,
    required String providerName,
    String? releaseName,
    String? sourceUrl,
    double? score,
    bool overrideEmbedded = false,
  }) {
    final normalizedLang = normalizeLang(lang);
    final path = sidecarPath(
      videoPath: videoPath,
      lang: normalizedLang,
      extension: payload.extension,
    );
    final out = File(path);
    out.writeAsBytesSync(payload.bytes, flush: true);
    final result = SourceSubtitleResult(
      path: path,
      language: normalizedLang,
      providerId: providerId,
      providerName: providerName,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      releaseName: releaseName ?? payload.fileName,
      sourceUrl: sourceUrl,
      score: score,
      overrideEmbedded: overrideEmbedded,
    );
    File(_metaPath(path)).writeAsStringSync(jsonEncode(result.toJson()));
    return result;
  }

  static Future<SourceSubtitleResult?> importFile({
    required String videoPath,
    required String lang,
    required String filePath,
  }) async {
    final f = File(filePath);
    if (!f.existsSync()) return null;
    final payload = unpackPayload(
      await f.readAsBytes(),
      fileName: p.basename(filePath),
    );
    if (payload == null) return null;
    await delete(videoPath: videoPath, lang: lang);
    return writePayload(
      videoPath: videoPath,
      lang: lang,
      payload: payload,
      providerId: 'manual-file',
      providerName: 'Manual file',
      releaseName: p.basename(filePath),
      sourceUrl: filePath,
      overrideEmbedded: true,
    );
  }

  static SourceSubtitlePayload? unpackPayload(
    Uint8List bytes, {
    String? fileName,
  }) {
    if (_isZip(bytes)) {
      try {
        final archive = ZipDecoder().decodeBytes(bytes);
        final files = archive.files.where((f) => f.isFile).toList();
        files.sort((a, b) {
          final ar = _extensionRank(p.extension(a.name));
          final br = _extensionRank(p.extension(b.name));
          if (ar != br) return ar.compareTo(br);
          return a.name.length.compareTo(b.name.length);
        });
        for (final file in files) {
          final ext = _cleanExtension(p.extension(file.name));
          if (!_extensions.contains(ext)) continue;
          final content = file.readBytes();
          if (content == null || content.isEmpty) continue;
          return SourceSubtitlePayload(
            bytes: Uint8List.fromList(content),
            extension: ext,
            fileName: p.basename(file.name),
          );
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    final ext = _extensionOrNull(p.extension(fileName ?? ''));
    final inferred = ext != null && _extensions.contains(ext)
        ? ext
        : _inferExtension(bytes);
    if (inferred == null) return null;
    return SourceSubtitlePayload(
      bytes: bytes,
      extension: inferred,
      fileName: fileName,
    );
  }

  static int _extensionRank(String raw) {
    final ext = _extensionOrNull(raw);
    if (ext == null) return 999;
    final idx = _extensions.indexOf(ext);
    return idx == -1 ? 999 : idx;
  }

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= _zipMagic.length &&
      Iterable<int>.generate(
        _zipMagic.length,
      ).every((i) => bytes[i] == _zipMagic[i]);

  static String? _inferExtension(Uint8List bytes) {
    final sample = utf8.decode(bytes.take(256).toList(), allowMalformed: true);
    if (sample.trimLeft().startsWith('WEBVTT')) return 'vtt';
    if (sample.contains('[Script Info]') || sample.contains('Dialogue:')) {
      return 'ass';
    }
    if (sample.contains('-->')) return 'srt';
    return null;
  }

  static String _cleanExtension(String extension) {
    return _extensionOrNull(extension) ?? 'srt';
  }

  static String? _extensionOrNull(String extension) {
    final clean = extension.trim().toLowerCase().replaceFirst('.', '');
    return clean.isEmpty ? null : clean;
  }

  static String _metaPath(String sidecarPath) => '$sidecarPath.json';
}

class _CandidateWithProvider {
  const _CandidateWithProvider(this.provider, this.candidate);

  final SourceSubtitleProvider provider;
  final SourceSubtitleCandidate candidate;
}
