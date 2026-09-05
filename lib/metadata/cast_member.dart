// CastMember — one cast entry from TMDB credits, rich enough for the Characters
// view: the character (role), the portraying actor (linked by TMDB person id), the
// gender the translator uses, billing order / episode count for "main-ness", and a
// profile photo path. Persisted inside TitleMetadata.

class CastMember {
  const CastMember({
    required this.personId,
    required this.actor,
    this.character,
    this.gender = '',
    this.order = 9999,
    this.profilePath,
    this.episodeCount,
    this.popularity,
    this.roleSummary,
  });

  /// TMDB person id — the link/tag to the portraying actor's metadata.
  final int personId;
  final String actor;
  final String? character;

  /// 'm' | 'f' | '' (unknown) — the gender fed to the translator.
  final String gender;

  /// Billing order (lower = more prominent). 9999 when unknown.
  final int order;

  /// TMDB profile image path (e.g. "/abc.jpg"); resolve via TmdbClient.profileUrl.
  final String? profilePath;

  /// TV only: episodes the character appears in (a "main-ness" signal).
  final int? episodeCount;
  final double? popularity;

  /// AI-generated one-line description of the character's part in the plot (TMDB has
  /// no per-character plot data). Null until generated; persisted once produced.
  final String? roleSummary;

  CastMember withSummary(String? summary) => CastMember(
        personId: personId,
        actor: actor,
        character: character,
        gender: gender,
        order: order,
        profilePath: profilePath,
        episodeCount: episodeCount,
        popularity: popularity,
        roleSummary: summary,
      );

  bool get isFemale => gender == 'f';
  bool get isMale => gender == 'm';
  String get displayCharacter =>
      (character?.trim().isNotEmpty ?? false) ? character!.trim() : 'Unknown role';

  /// TMDB person page — a stable external link for the actor.
  String get tmdbUrl => 'https://www.themoviedb.org/person/$personId';

  Map<String, dynamic> toJson() => {
        'person_id': personId,
        'actor': actor,
        'character': character,
        'gender': gender,
        'order': order,
        'profile_path': profilePath,
        'episode_count': episodeCount,
        'popularity': popularity,
        'role_summary': roleSummary,
      };

  factory CastMember.fromJson(Map<String, dynamic> j) => CastMember(
        personId: (j['person_id'] as num).toInt(),
        actor: j['actor'] as String,
        character: j['character'] as String?,
        gender: (j['gender'] as String?) ?? '',
        order: (j['order'] as num?)?.toInt() ?? 9999,
        profilePath: j['profile_path'] as String?,
        episodeCount: (j['episode_count'] as num?)?.toInt(),
        popularity: (j['popularity'] as num?)?.toDouble(),
        roleSummary: j['role_summary'] as String?,
      );
}
