import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:music_player/database/database.dart';

final _uuid = Uuid();

class PlaylistRepository {
  PlaylistRepository(this.db);
  final AppDatabase db;

  Future<List<Playlist>> all() =>
      (db.select(db.playlists)..orderBy([(pl) => OrderingTerm.asc(pl.name)])).get();

  Future<Playlist?> byId(String id) =>
      (db.select(db.playlists)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<Playlist> create(String name) async {
    final now = DateTime.now();
    final playlist = Playlist(id: _uuid.v4(), name: name, createdAt: now, updatedAt: now);
    await db.into(db.playlists).insert(playlist);
    return playlist;
  }

  Future<void> rename(String id, String name) =>
      (db.update(db.playlists)..where((p) => p.id.equals(id)))
          .write(PlaylistsCompanion(name: Value(name), updatedAt: Value(DateTime.now())));

  Future<void> delete(String id) =>
      (db.delete(db.playlists)..where((p) => p.id.equals(id))).go();

  Future<List<Track>> tracks(String playlistId, {int limit = 1000}) async {
    final rows = await (db.select(db.playlistTracks)
          ..where((pt) => pt.playlistId.equals(playlistId))
          ..orderBy([(pt) => OrderingTerm.asc(pt.position)])
          ..limit(limit))
        .get();
    if (rows.isEmpty) return const [];
    final all = await (db.select(db.tracks)..where((t) => t.id.isIn(rows.map((r) => r.trackId).toSet())))
        .get();
    final byId = {for (final t in all) t.id: t};
    return [for (final r in rows) if (byId.containsKey(r.trackId)) byId[r.trackId]!];
  }

  Future<int> trackCount(String playlistId) async {
    final countExpr = countAll();
    final rows = await (db.selectOnly(db.playlistTracks)
          ..addColumns([countExpr])
          ..where(db.playlistTracks.playlistId.equals(playlistId)))
        .get();
    return rows.first.read(countExpr) ?? 0;
  }

  /// Adds tracks (in order) skipping ones already present.
  Future<void> addTracks(String playlistId, List<String> trackIds) => db.transaction(() async {
        final existing = await (db.select(db.playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId)))
            .get();
        var position = existing.isEmpty ? 0 : (existing.map((e) => e.position).reduce((a, b) => a > b ? a : b) + 1);
        final toAdd = existing.map((e) => e.trackId).toSet();
        final records = <PlaylistTrack>[];
        for (final trackId in trackIds) {
          if (toAdd.contains(trackId)) continue;
          records.add(PlaylistTrack(playlistId: playlistId, trackId: trackId, position: position++));
        }
        if (records.isNotEmpty) {
          await db.batch((b) => b.insertAll(db.playlistTracks, records,
              mode: InsertMode.insertOrReplace));
        }
        await (db.update(db.playlists)..where((p) => p.id.equals(playlistId)))
            .write(PlaylistsCompanion(updatedAt: Value(DateTime.now())));
      });

  Future<void> removeTrack(String playlistId, String trackId) => db.transaction(() async {
        await (db.delete(db.playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId)))
            .go();
        await _reindex(playlistId);
      });

  /// Reorders tracks to the given id sequence.
  Future<void> reorder(String playlistId, List<String> orderedTrackIds) =>
      db.transaction(() async {
        final existing = await (db.select(db.playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId)))
            .get();
        for (var i = 0; i < existing.length && i < orderedTrackIds.length; i++) {
          final row = existing[i];
          if (row.trackId != orderedTrackIds[i]) {
            await (db.update(db.playlistTracks)
                  ..where((pt) =>
                      pt.playlistId.equals(playlistId) & pt.trackId.equals(row.trackId)))
                .write(PlaylistTracksCompanion(position: Value(i)));
          }
        }
        await _reindex(playlistId);
      });

  Future<void> _reindex(String playlistId) async {
    final rows = await (db.select(db.playlistTracks)
          ..where((pt) => pt.playlistId.equals(playlistId))
          ..orderBy([(pt) => OrderingTerm.asc(pt.position)]))
        .get();
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position != i) {
        await (db.update(db.playlistTracks)
              ..where((pt) =>
                  pt.playlistId.equals(playlistId) & pt.trackId.equals(rows[i].trackId)))
            .write(PlaylistTracksCompanion(position: Value(i)));
      }
    }
  }

  /// Exports a playlist as an M3U8 playlist file.
  Future<File> exportM3U(String playlistId, String targetDir) async {
    final list = await tracks(playlistId);
    final playlist = await byId(playlistId);
    final lines = <String>['#EXTM3U'];
    for (final t in list) {
      lines.add('#EXTINF:${(t.durationMs / 1000).floor()},${t.artist} - ${t.title}');
      lines.add(t.filePath);
    }
    final file = File(p.join(targetDir, '${(playlist?.name ?? 'playlist').replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '')}.m3u8'));
    await file.writeAsString(lines.join('\n'));
    return file;
  }
}

class SettingsRepository {
  SettingsRepository(this.db);
  final AppDatabase db;

  Future<String?> get(String key) async {
    final row = await (db.select(db.appSettings)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) =>
      db.into(db.appSettings)
          .insert(AppSetting(key: key, value: value),
              onConflict: DoUpdate((old) => AppSettingsCompanion(value: Value(value))));

  Future<Map<String, String>> all() async {
    final rows = await db.select(db.appSettings).get();
    return {for (final r in rows) r.key: r.value};
  }
}

class HistoryRepository {
  HistoryRepository(this.db);
  final AppDatabase db;

  Future<List<(Track, DateTime)>> recent({int limit = 100}) async {
    final rows = await (db.select(db.playbackHistory)
          ..orderBy([(h) => OrderingTerm.desc(h.playedAt)])
          ..limit(limit))
        .get();
    if (rows.isEmpty) return const [];
    final tracks = await (db.select(db.tracks)..where((t) => t.id.isIn(rows.map((r) => r.trackId).toSet())))
        .get();
    final byId = {for (final t in tracks) t.id: t};
    final result = <(Track, DateTime)>[];
    for (final r in rows) {
      final t = byId[r.trackId];
      if (t != null) result.add((t, r.playedAt));
    }
    return result;
  }

  Future<void> clear() => (db.delete(db.playbackHistory)).go();
}
