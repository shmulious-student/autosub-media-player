import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/metadata/cast_member.dart';
import 'package:autosub_media_player/metadata/title_metadata.dart';
import 'package:autosub_media_player/metadata/tmdb_client.dart';

void main() {
  test('TmdbResult parses and round-trips original_language', () {
    final parsed = TmdbResult.fromJson(const {
      'id': 42,
      'media_type': 'movie',
      'name': 'Amelie',
      'original_language': 'fr',
    });
    expect(parsed.originalLanguage, 'fr');
    expect(TmdbResult.fromJson(parsed.toJson()).originalLanguage, 'fr');
    // Confidence-copy preserves it.
    expect(parsed.withConfidence(0.9).originalLanguage, 'fr');
  });

  test('TitleMetadata round-trips original_language', () {
    const m = TitleMetadata(path: '/m/Amelie.mkv', tmdbId: 42, originalLanguage: 'fr');
    final back = TitleMetadata.fromJson(m.toJson());
    expect(back.originalLanguage, 'fr');
    expect(m.copyWith(originalLanguage: 'ja').originalLanguage, 'ja');
  });

  test('parseCredits maps actor + character names to gender (movie shape)', () {
    final map = TmdbClient.parseCredits({
      'cast': [
        {'name': 'Mel Brooks', 'character': 'Rabbi Tuckman', 'gender': 2},
        {'name': 'Amy Yasbeck', 'character': 'Marian', 'gender': 1},
        {'name': 'Unknown Person', 'character': 'Extra', 'gender': 0}, // skipped
      ],
      'crew': [
        {'name': 'Some Director', 'gender': 2, 'job': 'Director'},
        {'name': 'A Gaffer', 'gender': 2, 'job': 'Gaffer'}, // not a wanted job
      ],
    });
    expect(map['Mel Brooks'], 'm');
    expect(map['Rabbi Tuckman'], 'm');
    expect(map['Amy Yasbeck'], 'f');
    expect(map['Marian'], 'f');
    expect(map.containsKey('Unknown Person'), false);
    expect(map['Some Director'], 'm');
    expect(map.containsKey('A Gaffer'), false);
  });

  test('parseCredits handles tv aggregate_credits roles shape', () {
    final map = TmdbClient.parseCredits({
      'cast': [
        {'name': 'Jane Doe', 'gender': 1, 'roles': [{'character': 'Captain Reyes'}]},
      ],
    });
    expect(map['Jane Doe'], 'f');
    expect(map['Captain Reyes'], 'f');
  });

  test('TitleMetadata round-trips characters map', () {
    const m = TitleMetadata(path: '/m/x.mkv', characters: {'Mel Brooks': 'm'});
    expect(TitleMetadata.fromJson(m.toJson()).characters['Mel Brooks'], 'm');
  });

  test('parseCast builds billing-ordered cast (movie + tv shapes)', () {
    final cast = TmdbClient.parseCast({
      'cast': [
        {'id': 2, 'name': 'Cary Elwes', 'character': 'Robin Hood', 'gender': 2, 'order': 0, 'profile_path': '/a.jpg'},
        {'id': 5, 'name': 'Amy Yasbeck', 'gender': 1, 'order': 1, 'total_episode_count': 3, 'roles': [{'character': 'Maid Marian'}]},
        {'id': 9, 'name': 'Bit Part', 'character': 'Extra', 'order': 2},
      ],
    });
    expect(cast.length, 3);
    expect(cast.first.actor, 'Cary Elwes');
    expect(cast.first.character, 'Robin Hood');
    expect(cast.first.gender, 'm');
    expect(cast.first.personId, 2);
    expect(cast[1].character, 'Maid Marian'); // tv aggregate roles[].character
    expect(cast[1].gender, 'f');
    expect(cast[1].episodeCount, 3);
    expect(cast[2].gender, ''); // unknown gender kept (still shown as a character)
  });

  test('CastMember round-trips', () {
    const c = CastMember(
        personId: 2, actor: 'Cary Elwes', character: 'Robin Hood',
        gender: 'm', order: 0, profilePath: '/a.jpg', episodeCount: 3);
    final back = CastMember.fromJson(c.toJson());
    expect(back.personId, 2);
    expect(back.character, 'Robin Hood');
    expect(back.gender, 'm');
    expect(back.episodeCount, 3);
    expect(back.tmdbUrl, 'https://www.themoviedb.org/person/2');
  });
}
