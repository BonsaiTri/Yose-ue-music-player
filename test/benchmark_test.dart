import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';

/// Spec §17.1 / §19: the database must handle a 20,000+ track library
/// without blocking the UI. Synthetic tracks (no real audio files) are
/// batch-inserted, then the queries the UI actually issues are timed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final uuid = const Uuid();
  const totalTracks = 20000;

  late Directory temp;
  late AppDatabase db;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('bench_test_');
    db = AppDatabase.withFile(File(p.join(temp.path, 'bench.sqlite')));

    final now = DateTime.now();
    final insertStart = DateTime.now();
    await db.batch((batch) {
      for (var i = 0; i < totalTracks; i++) {
        batch.insert(
          db.tracks,
          TracksCompanion(
          id: Value(uuid.v4()),
          title: Value('Synth Track $i'),
          artist: Value('Bench Artist ${(i % 500)}'),
          album: Value('Bench Album ${(i % 200)}'),
          filePath: Value('/nonexistent/${uuid.v4()}.flac'),
          fileFormat: Value('flac'),
          durationMs: Value(60000 + (i % 180000)),
          playCount: Value(i % 25),
          dateAdded: Value(now),
          dateModified: Value(now),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      }
    });
    // ignore: avoid_print
    print('bench: inserted $totalTracks tracks in '
        '${DateTime.now().difference(insertStart).inMilliseconds}ms');
  });

  tearDownAll(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('library queries stay fast with 20,000+ tracks', () async {
    final count = await TrackRepository(db).trackCount();
    expect(count, greaterThanOrEqualTo(20000));

    // Paginated page at the start of the list.
    final t0 = DateTime.now();
    final page1 =
        await (db.select(db.tracks)..limit(200)).get();
    expect(page1.length, 200);
    final page1Ms = DateTime.now().difference(t0).inMilliseconds;

    // A deep page (offset near the end of the list).
    final t1 = DateTime.now();
    final page2 =
        await (db.select(db.tracks)..limit(200, offset: 19800)).get();
    expect(page2.length, greaterThan(0));
    final page2Ms = DateTime.now().difference(t1).inMilliseconds;

    // FTS search across the whole library.
    final t2 = DateTime.now();
    final matches = await db.searchTracksIds('Synth Track 1234');
    expect(matches, isNotEmpty);
    final ftsMs = DateTime.now().difference(t2).inMilliseconds;

    // UI-blocking budget: each read must finish well under a second
    // (the UI's patience threshold is far below this).
    expect(page1Ms, lessThan(1000));
    expect(page2Ms, lessThan(1000));
    expect(ftsMs, lessThan(2000));
    // ignore: avoid_print
    print('bench: page1=${page1Ms}ms deep-page=${page2Ms}ms fts=${ftsMs}ms');
  });
}
