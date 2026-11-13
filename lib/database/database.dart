import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'package:music_player/database/tables/tables.dart';
export 'package:music_player/database/tables/tables.dart';

part 'database.g.dart';

/// Application database.
///
/// Uses SQLite (WAL) with foreign-key enforcement, an FTS5 search index
/// kept in sync by triggers, and versioned migrations.
@DriftDatabase(
  tables: [
    Artists,
    Albums,
    Genres,
    Tracks,
    Playlists,
    PlaylistTracks,
    Favorites,
    PlaybackHistory,
    DownloadTasks,
    AppSettings,
    Artwork,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(QueryExecutor e) : super(e);

  AppDatabase.withFile(File file) : super(NativeDatabase(file));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: _migrateToV1,
      onUpgrade: (m, from, to) async {
        if (from < 1) await _migrateToV1(m);
        if (from < 2) await _migrateToV2(m);
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _migrateToV1(Migrator m) async {
    await m.createAll();

    await customStatement('PRAGMA journal_mode = WAL');

    // FTS5 external-content index over track metadata.
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
        title,
        artist,
        album,
        album_artist,
        genre,
        content='tracks',
        content_rowid='rowid'
      )
    ''');

    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS tracks_fts_ai AFTER INSERT ON tracks
      BEGIN
        INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, genre)
        VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.genre);
      END
    ''');

    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS tracks_fts_ad AFTER DELETE ON tracks
      BEGIN
        INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, genre)
        VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.genre);
      END
    ''');

    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS tracks_fts_au AFTER UPDATE ON tracks
      BEGIN
        INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, genre)
        VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.genre);
        INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, genre)
        VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.genre);
      END
    ''');
  }

  Future<void> _migrateToV2(Migrator m) async {
    // Spec §17.1: indexes for frequently queried status/availability fields.
    await customStatement(
        'CREATE INDEX IF NOT EXISTS tracks_file_availability ON tracks(file_availability)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS download_tasks_status ON download_tasks(status)');
  }

  /// Full-text search over track metadata. Returns matching track ids in
  /// ranked order (best matches first).
  Future<List<String>> searchTracksIds(String query, {int limit = 200}) async {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return const [];
    final escaped = tokens
        .map((t) => '"${t.replaceAll('"', '""')}"*')
        .join(' ');
    final matches = await customSelect(
      'SELECT rowid, rank FROM tracks_fts WHERE tracks_fts MATCH ? ORDER BY rank LIMIT ?',
      variables: [Variable(escaped), Variable(limit)],
    ).get();
    if (matches.isEmpty) return const [];
    final rowids = matches.map((r) => r.read<int>('rowid')).toList();
    // rowids come from our own query (integers) so inline interpolation is safe.
    final rows = await customSelect(
      'SELECT rowid, id FROM tracks WHERE rowid IN (${rowids.join(',')})'
    ).get();
    final idByRowid = {for (final r in rows) r.read<int>('rowid'): r.read<String>('id')};
    return [for (final r in rowids)
      if (idByRowid.containsKey(r)) idByRowid[r]!];
  }
}
