// Filename parser tests (lib/metadata/filename_parser.dart) — these drive TMDB
// match quality, so the common scene-naming patterns are pinned here.

import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/metadata/filename_parser.dart';

void main() {
  test('movie with year in parens', () {
    final r = parseFilename('/m/Foundation (2021).mkv');
    expect(r.title, 'Foundation');
    expect(r.year, 2021);
    expect(r.isSeries, isFalse);
  });

  test('movie with dotted scene name + quality tags', () {
    final r = parseFilename('/m/Blade.Runner.2049.2017.1080p.BluRay.x264.mkv');
    expect(r.title, 'Blade Runner 2049');
    expect(r.year, 2017);
  });

  test('series SxxExx', () {
    final r = parseFilename('/tv/Foundation.S02E01.1080p.WEB.mkv');
    expect(r.title, 'Foundation');
    expect(r.season, 2);
    expect(r.episode, 1);
    expect(r.isSeries, isTrue);
  });

  test('series NxNN form', () {
    final r = parseFilename('/tv/The.Expanse.1x05.HDTV.mkv');
    expect(r.title, 'The Expanse');
    expect(r.season, 1);
    expect(r.episode, 5);
  });

  test('bracketed release group is dropped', () {
    final r = parseFilename('/m/[Group] Dune (2021) [1080p].mkv');
    expect(r.title, 'Dune');
    expect(r.year, 2021);
  });
}
