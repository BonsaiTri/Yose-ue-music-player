// Unit tests for the library duplicate finder.
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/library/domain/duplicate_finder.dart';

Track _track(
  String id,
  String title, {
  String artist = 'Artist A',
  int playCount = 0,
  int durationMs = 120000,
  String? contentHash,
  DateTime? dateAdded,
}) {
  return Track(
    id: id,
    title: title,
    artist: artist,
    album: 'Unknown Album',
    durationMs: durationMs,
    filePath: '/tmp/$id.m4a',
    fileFormat: 'm4a',
    contentHash: contentHash,
    playCount: playCount,
    skipCount: 0,
    favorite: false,
    sourceType: 'local',
    dateAdded: dateAdded ?? DateTime(2026, 1, 1),
    dateModified: DateTime(2026, 1, 1),
    fileAvailability: FileAvailability.available,
  );
}

void main() {
  test('no duplicates returns empty', () {
    final groups = findDuplicates([
      _track('1', 'Alpha', artist: 'A'),
      _track('2', 'Beta', artist: 'B'),
      _track('3', 'Gamma', artist: 'C'),
    ]);
    expect(groups, isEmpty);
  });

  test('same normalized title and artist group together', () {
    final groups = findDuplicates([
      _track('1', 'Sunset Drive (Official Video)', artist: 'Neon Waves'),
      _track('2', 'sunset drive', artist: 'Neon Waves!'),
      _track('3', 'Other Song', artist: 'Neon Waves'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.first.tracks.map((t) => t.id).toSet(), {'1', '2'});
  });

  test('same title but different artist is not a duplicate', () {
    final groups = findDuplicates([
      _track('1', 'Same Name', artist: 'Artist A'),
      _track('2', 'Same Name', artist: 'Artist B'),
    ]);
    expect(groups, isEmpty);
  });

  test('same title with an unknown artist is treated as a duplicate', () {
    final groups = findDuplicates([
      _track('1', 'Ghost Song', artist: 'Ghost'),
      _track('2', 'Ghost Song (Remix)', artist: ''),
    ]);
    expect(groups, hasLength(1));
  });

  test('same content hash groups tracks even with different titles', () {
    final groups = findDuplicates([
      _track('1', 'Remix Title', artist: 'X', contentHash: 'abc123'),
      _track('2', 'Original Title', artist: 'Y', contentHash: 'abc123'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.first.tracks.map((t) => t.id).toSet(), {'1', '2'});
  });

  test('similar titles (variant words only) group together', () {
    final groups = findDuplicates([
      _track('1', 'Sunset Drive', artist: 'Neon Waves'),
      _track('2', 'Sunset Drive Remix', artist: 'Neon Waves'),
      _track('3', 'Official Video: Neon', artist: 'Neon Waves'),
      _track('4', 'Neon', artist: 'Neon Waves'),
    ]);
    expect(groups, hasLength(2));
    final byMembers =
        groups.map((g) => g.tracks.map((t) => t.id).toSet()).toSet();
    expect(byMembers, containsAll({
      {'1', '2'},
      {'3', '4'},
    }));
  });

  test('similar-looking but different songs do not group', () {
    final groups = findDuplicates([
      _track('1', 'Take Me Home', artist: 'Artist A'),
      _track('2', 'Take Me Home Country', artist: 'Artist A'),
      _track('3', 'Homeward', artist: 'Artist A'),
      _track('4', 'Home', artist: 'Artist A'),
    ]);
    expect(groups, isEmpty);
  });

  test('similar titles with different artists do not group', () {
    final groups = findDuplicates([
      _track('1', 'Sunset Drive', artist: 'Artist A'),
      _track('2', 'Sunset Drive Remix', artist: 'Artist B'),
    ]);
    expect(groups, isEmpty);
  });

  test('similar title with an unknown artist is treated as a duplicate', () {
    final groups = findDuplicates([
      _track('1', 'Sunset Drive Remix', artist: 'Neon Waves'),
      _track('2', 'Sunset Drive', artist: ''),
    ]);
    expect(groups, hasLength(1));
    expect(groups.first.tracks.map((t) => t.id).toSet(), {'1', '2'});
  });

  test('keeper is recommended by play count, then duration, then age', () {
    final groups = findDuplicates([
      _track('1', 'Song', playCount: 5, durationMs: 100000),
      _track('2', 'Song', playCount: 20, durationMs: 120000),
      _track('3', 'Song', playCount: 20, durationMs: 90000,
          dateAdded: DateTime(2025, 1, 1)),
    ]);
    expect(groups, hasLength(1));
    // Tie on play count: longer track first, then older track first.
    expect(groups.first.tracks.map((t) => t.id).toList(), ['2', '3', '1']);
    expect(groups.first.keeper.id, '2');
  });

  test('extras are everyone but the keeper', () {
    final groups = findDuplicates([
      _track('1', 'Song', playCount: 1),
      _track('2', 'Song', playCount: 9),
      _track('3', 'Song', playCount: 5),
    ]);
    expect(groups.first.keeper.id, '2');
    expect(groups.first.extras.map((t) => t.id).toSet(), {'1', '3'});
  });
}
