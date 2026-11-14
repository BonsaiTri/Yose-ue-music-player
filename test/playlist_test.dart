// Playlist repository behavior: create/rename/delete, ordered adds with
// dedupe, remove-with-reindex, reorder, and track counts.
import 'dart:io';

import 'package:drift/drift.dart'
    show driftRuntimeOptions, Value, OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const uuid = Uuid();

  late Directory temp;
  late AppDatabase db;
  late PlaylistRepository playlists;

  Future<String> makeTrack({String title = 'T', String artist = 'A'}) async {
    final now = DateTime.now();
    final id = uuid.v4();
    await db
        .into(db.tracks)
        .insert(TracksCompanion(
          id: Value(id),
          title: Value(title),
          artist: Value(artist),
          album: Value('Album'),
          filePath: Value('/nonexistent/$id.flac'),
          fileFormat: Value('flac'),
          durationMs: Value(60000),
          dateAdded: Value(now),
          dateModified: Value(now),
        ));
    return id;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('playlist_test_');
    db = AppDatabase.withFile(File(p.join(temp.path, 'test.sqlite')));
    playlists = PlaylistRepository(db);
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('create lists alphabetically and rename updates the name', () async {
    final b = await playlists.create('Beta');
    await playlists.create('Alpha');
    final all = await playlists.all();
    expect(all.map((x) => x.name).toList(), ['Alpha', 'Beta']);
    await playlists.rename(b.id, 'Gamma');
    final names = (await playlists.all()).map((x) => x.name).toList();
    expect(names, ['Alpha', 'Gamma']);
  });

  test('addTracks appends in order and skips duplicates', () async {
    final pl = await playlists.create('Mix');
    final t1 = await makeTrack(title: 'One');
    final t2 = await makeTrack(title: 'Two');
    final t3 = await makeTrack(title: 'Three');

    await playlists.addTracks(pl.id, [t1, t2]);
    expect((await playlists.tracks(pl.id)).map((t) => t.title).toList(),
        ['One', 'Two']);

    // Duplicate (including a repeat inside the same batch) is skipped.
    await playlists.addTracks(pl.id, [t2, t3, t1]);
    expect((await playlists.tracks(pl.id)).map((t) => t.title).toList(),
        ['One', 'Two', 'Three']);
    expect(await playlists.trackCount(pl.id), 3);
  });

  test('removeTrack removes the entry and reindexes positions', () async {
    final pl = await playlists.create('Mix');
    final t1 = await makeTrack(title: 'One');
    final t2 = await makeTrack(title: 'Two');
    final t3 = await makeTrack(title: 'Three');
    await playlists.addTracks(pl.id, [t1, t2, t3]);

    await playlists.removeTrack(pl.id, t2);
    final tracks = await playlists.tracks(pl.id);
    expect(tracks.map((t) => t.title).toList(), ['One', 'Three']);
    // Positions must be contiguous 0..n-1 after the removal.
    final rows = await (db.select(db.playlistTracks)
          ..where((pt) => pt.playlistId.equals(pl.id))
          ..orderBy([(pt) => OrderingTerm.asc(pt.position)]))
        .get();
    expect(rows.map((r) => r.position).toList(), [0, 1]);
    expect(await playlists.trackCount(pl.id), 2);

    // Removing a track that is not in the playlist is a no-op.
    await playlists.removeTrack(pl.id, t1);
    expect(await playlists.trackCount(pl.id), 1);
  });

  test('reorder applies the given id sequence', () async {
    final pl = await playlists.create('Mix');
    final t1 = await makeTrack(title: 'One');
    final t2 = await makeTrack(title: 'Two');
    final t3 = await makeTrack(title: 'Three');
    await playlists.addTracks(pl.id, [t1, t2, t3]);

    await playlists.reorder(pl.id, [t3, t1, t2]);
    expect((await playlists.tracks(pl.id)).map((t) => t.title).toList(),
        ['Three', 'One', 'Two']);

    // Moving one track to the front keeps the others' relative order.
    await playlists.reorder(pl.id, [t2]);
    expect((await playlists.tracks(pl.id)).map((t) => t.title).toList(),
        ['Two', 'Three', 'One']);
  });

  test('delete removes the playlist and its entries', () async {
    final pl = await playlists.create('Mix');
    final t1 = await makeTrack();
    await playlists.addTracks(pl.id, [t1]);
    await playlists.delete(pl.id);

    expect(await playlists.byId(pl.id), isNull);
    final rows = await (db.select(db.playlistTracks)
          ..where((pt) => pt.playlistId.equals(pl.id)))
        .get();
    expect(rows, isEmpty);
  });
}
