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
/// Two tracks are considered the same song when their normalized
/// title keys match, or when both carry the same non-null content hash
/// (identical file bytes, even if the titles differ).
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
