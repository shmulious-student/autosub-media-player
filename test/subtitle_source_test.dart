import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:autosub_media_player/metadata/subtitle_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('autosub-source-test-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('writes source sidecar with provider metadata', () {
    final video = '${temp.path}/Movie.mkv';
    File(video).writeAsStringSync('');

    final result = SourceSubtitleCache.writePayload(
      videoPath: video,
      lang: 'eng',
      payload: SourceSubtitlePayload(
        bytes: srtBytes(),
        extension: 'srt',
        fileName: 'Movie.English.srt',
      ),
      providerId: 'test-provider',
      providerName: 'Test Provider',
      releaseName: 'Movie.English.srt',
      overrideEmbedded: true,
    );

    expect(result.path, '${temp.path}/Movie.en.src.srt');
    expect(File(result.path).existsSync(), true);

    final cached = SourceSubtitleCache.read(videoPath: video, lang: 'en');
    expect(cached, isNotNull);
    expect(cached!.providerName, 'Test Provider');
    expect(cached.overrideEmbedded, true);
  });

  test('unpacks first subtitle file from zip payload', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('readme.txt', 'not a subtitle'))
      ..addFile(ArchiveFile.string('Movie.en.srt', srtText));
    final zipped = ZipEncoder().encode(archive);

    final payload = SourceSubtitleCache.unpackPayload(
      Uint8List.fromList(zipped),
      fileName: 'Movie.en.zip',
    );

    expect(payload, isNotNull);
    expect(payload!.extension, 'srt');
    expect(payload.fileName, 'Movie.en.srt');
    expect(String.fromCharCodes(payload.bytes), contains('Hello.'));
  });

  test('rejects extensionless non-subtitle payloads', () {
    final payload = SourceSubtitleCache.unpackPayload(
      Uint8List.fromList('<html>not a subtitle</html>'.codeUnits),
      fileName: 'download',
    );

    expect(payload, isNull);
  });
}

const srtText = '''
1
00:00:01,000 --> 00:00:02,000
Hello.
''';

Uint8List srtBytes() => Uint8List.fromList(srtText.codeUnits);
