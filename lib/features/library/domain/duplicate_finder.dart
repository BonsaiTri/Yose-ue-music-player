import 'package:music_player/core/services/song_key.dart';
import 'package:music_player/database/database.dart';

/// A set of library tracks that represent the same song.
///
/// [tracks] is ordered with the recommended keeper first (most played,
/// then longest, then earliest added).
class DuplicateGroup {
  DuplicateGroup({required this.key, required this.titleKey, required this.tracks})
      : keeper = tracks.first;

  /// Unique identifier for this group (used for state keys).
  final String key;

  /// Normalized title used to group the tracks (for display).
  final String titleKey;

  /// All tracks in the group, keeper first.
  final List<Track> tracks;

  /// The track recommended to keep.
  final Track keeper;

  /// The extra copies that should be deleted (everyone but the keeper).
  List<Track> get extras => tracks.sublist(1);
}

/// Finds groups of two or more library tracks that represent the same
/// song.
///
/// Two tracks are considered the same song when any of these hold:
/// * their normalized title keys match exactly,
/// * their normalized titles are *similar* — one contains the other and
///   the extra words are only known variant words (remix, live, official,
///   video, slowed, reverb, …) — with the same artist (or an unknown
///   artist on either side), or
/// * both carry the same non-null content hash (identical file bytes,
///   even if the titles differ).
List<DuplicateGroup> findDuplicates(List<Track> tracks) {
  final parent = List<int>.generate(tracks.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b) => parent[find(a)] = find(b);

  final byTitle = <String, List<int>>{};
  final byHash = <String, List<int>>{};
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    final key = songKey(t.title);
    if (key.isNotEmpty) byTitle.putIfAbsent(key, () => []).add(i);
    final hash = t.contentHash;
    if (hash != null && hash.isNotEmpty) {
      byHash.putIfAbsent(hash, () => []).add(i);
    }
  }
  byTitle.values.forEach((idxs) {
    // Same title: duplicates when the artists match, or when either
    // artist is unknown (conservative, same rule as the download engine).
    for (var i = 0; i < idxs.length; i++) {
      final ai = songKey(tracks[idxs[i]].artist);
      for (var j = i + 1; j < idxs.length; j++) {
        final aj = songKey(tracks[idxs[j]].artist);
        if (ai.isEmpty || aj.isEmpty || ai == aj) union(idxs[i], idxs[j]);
      }
    }
  });

  // Similar titles: one title contains the other and the difference is
  // only variant words ("Sunset Drive" vs. "Sunset Drive Remix").
  // Compare within artist buckets (plus unknown-artist tracks, same
  // conservative rule as the exact pass) so different artists never mix.
  final keys = [
    for (var i = 0; i < tracks.length; i++) songKey(tracks[i].title)
  ];
  final byArtist = <String, List<int>>{};
  final noArtist = <int>[];
  for (var i = 0; i < tracks.length; i++) {
    final ak = songKey(tracks[i].artist);
    if (ak.isEmpty) {
      noArtist.add(i);
    } else {
      byArtist.putIfAbsent(ak, () => []).add(i);
    }
  }
  void _maybeSimilar(int i, Iterable<int> candidates) {
    final ka = keys[i];
    if (ka.isEmpty) return;
    for (final j in candidates) {
      if (j == i) continue;
      final kb = keys[j];
      if (kb.isEmpty || ka == kb) continue; // exact pass already handled it
      // Variant words can only add a bounded amount of length.
      if ((ka.length - kb.length).abs() > 24) continue;
      if (_similarTitleKeys(ka, kb)) union(i, j);
    }
  }

  for (var i = 0; i < tracks.length; i++) {
    final ak = songKey(tracks[i].artist);
    _maybeSimilar(i, byArtist[ak] ?? const <int>[]);
    if (ak.isNotEmpty) _maybeSimilar(i, noArtist);
  }

  byHash.values.forEach((idxs) {
    for (var i = 1; i < idxs.length; i++) union(idxs[0], idxs[i]);
  });

  final clusters = <int, List<int>>{};
  for (var i = 0; i < tracks.length; i++) {
    clusters.putIfAbsent(find(i), () => []).add(i);
  }

  final raw = <(String, List<Track>)>[];
  clusters.values.forEach((idxs) {
    if (idxs.length < 2) return;
    final members = idxs.map((i) => tracks[i]).toList()
      ..sort((a, b) {
        final byPlay = b.playCount.compareTo(a.playCount);
        if (byPlay != 0) return byPlay;
        final byDur = b.durationMs.compareTo(a.durationMs);
        if (byDur != 0) return byDur;
        return a.dateAdded.compareTo(b.dateAdded);
      });
    raw.add((songKey(members.first.title), members));
  });
  raw.sort((a, b) => a.$1.compareTo(b.$1));

  // Make keys unique (two groups can show the same title, e.g. different
  // artists whose files happen to share a content hash).
  final seen = <String, int>{};
  final groups = <DuplicateGroup>[];
  for (final (titleKey, members) in raw) {
    var key = titleKey;
    final n = seen[titleKey] ?? 0;
    if (n > 0) key = '$titleKey#$n';
    seen[titleKey] = n + 1;
    groups.add(DuplicateGroup(key: key, titleKey: titleKey, tracks: members));
  }
  return groups;
}

/// Words that mark a known variant of the same song rather than a
/// different song ("Sunset Drive Remix", "Official Video", "(Live)", …).
const Set<String> _variantWords = {
  'remix', 'remixes', 'remastered', 'remaster', 'live', 'official',
  'video', 'mvs', 'audio', 'song', 'instrumental', 'inst', 'slowed',
  'reverb', 'acoustic', 'cover', 'covers', 'session', 'sessions',
  'edit', 'mix', 'mixed', 'radio', 'single', 'version', 'ver', 'feat',
  'featuring', 'ft', 'karaoke', 'uncensored', 'explicit', 'clean',
  'demo', 'preview', 'full', 'hd', '4k', 'hq', 'stereo', 'visualizer',
  'lyric', 'lyrics', 'officialaudio', 'officialvideo',
};

/// True when two distinct normalized title keys are similar: one is a
/// whole-word substring of the other and every extra word is a known
/// variant word. "sunset drive" vs. "sunset drive remix" → true;
/// "take me home" vs. "take me home country" → false.
bool _similarTitleKeys(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  String shortKey = a;
  String longKey = b;
  if (shortKey.length > longKey.length) {
    shortKey = b;
    longKey = a;
  }
  if (shortKey == longKey) return false;
  final idx = _wholeWordIndex(longKey, shortKey);
  if (idx < 0) return false;
  final head = idx == 0 ? '' : longKey.substring(0, idx - 1);
  final tail = idx + shortKey.length == longKey.length
      ? ''
      : longKey.substring(idx + shortKey.length + 1);
  final extra =
      '$head $tail'.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (extra.isEmpty) return false;
  return extra.every(_variantWords.contains);
}

/// Index of [needle] inside [haystack] bounded by word boundaries
/// (keys are single-space separated), or -1.
int _wholeWordIndex(String haystack, String needle) {
  var from = 0;
  while (true) {
    final i = haystack.indexOf(needle, from);
    if (i < 0) return -1;
    final before = i == 0 ? ' ' : haystack[i - 1];
    final after = i + needle.length >= haystack.length
        ? ' '
        : haystack[i + needle.length];
    if (before == ' ' && after == ' ') return i;
    from = i + 1;
  }
}
