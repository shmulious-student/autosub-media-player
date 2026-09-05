// Grouping tests (lib/library/library_grouping.dart). With no TMDB metadata, the
// grouping falls back to the filename parse — so these pin the series/movie split
// and the season ordering purely from filenames.

import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/library/library_grouping.dart';
import 'package:autosub_media_player/library/library_store.dart';
import 'package:autosub_media_player/metadata/metadata_store.dart';

LibraryEntry _e(String path, int addedAtMs) =>
    LibraryEntry(path: path, addedAtMs: addedAtMs);

void main() {
  // A metadata store with no key + no cache → metadataFor() is always null, so
  // grouping uses the filename parse.
  final metadata = MetadataStore(apiKey: () => '');

  test('episodes of a series collapse into one group; movies stay standalone', () {
    final entries = [
      _e('/tv/Foundation.S02E01.1080p.mkv', 5),
      _e('/tv/Foundation.S02E02.1080p.mkv', 4),
      _e('/tv/Foundation.S01E01.1080p.mkv', 3),
      _e('/m/Dune (2021).mkv', 2),
      _e('/m/Robin Hood Men in Tights (1993).mkv', 1),
    ];
    final groups = groupLibrary(entries, metadata);

    final series = groups.where((g) => g.isSeries).toList();
    final movies = groups.where((g) => !g.isSeries).toList();
    expect(series.length, 1);
    expect(movies.length, 2);

    final foundation = series.single;
    expect(foundation.title.toLowerCase(), 'foundation');
    expect(foundation.count, 3);
  });

  test('seasons sort ascending, episodes within a season sort ascending', () {
    final entries = [
      _e('/tv/Foundation.S02E02.mkv', 4),
      _e('/tv/Foundation.S02E01.mkv', 3),
      _e('/tv/Foundation.S01E01.mkv', 2),
    ];
    final foundation = groupLibrary(entries, metadata).single;
    final seasons = groupSeasons(foundation, metadata);

    expect(seasons.map((s) => s.season).toList(), [1, 2]);
    expect(seasons[1].episodes.length, 2);
    // S2 episodes in order E1, E2.
    final eps = seasons[1]
        .episodes
        .map((e) => episodeNumberOf(e, metadata).episode)
        .toList();
    expect(eps, [1, 2]);
  });
}
