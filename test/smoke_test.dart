// Compile + render smoke test: boots the real dependency graph (real Drift
// database in a temp dir, no audio engine init) and pumps the full app shell
// and key widgets under a real ProviderContainer.
//
// Note: `testWidgets` runs its body in a FakeAsync zone. Real async work
// (file I/O, sqlite) must be performed inside `tester.runAsync(...)`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:music_player/app/app.dart';
import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/services/artwork_service.dart';
import 'package:music_player/core/services/backup_service.dart';
import 'package:music_player/core/services/diagnostics_service.dart';
import 'package:music_player/core/services/file_lock_manager.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/core/services/metadata_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/download_repository.dart';
import 'package:music_player/database/repositories/library_repository.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';
import 'package:music_player/features/downloader/domain/download_engine.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';
import 'package:music_player/features/player/domain/playback_controller.dart';
import 'package:music_player/shared/themes/app_theme.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

Future<ProviderContainer> makeContainer() async {
  final tempDir = await Directory.systemTemp.createTemp('music_player_test_');
  final root = tempDir.path;
  final files = FileService(root);
  await files.ensureDirectories();

  final dbFile = File(p.join(files.databaseDir, 'music_player.sqlite'));
  final db = AppDatabase.withFile(dbFile);
  final tracks = TrackRepository(db);
  final artists = ArtistRepository(db);
  final albums = AlbumRepository(db);
  final genres = GenreRepository(db);
  final metadata = MetadataService(binDir: files.binDir);
  final artwork = ArtworkService(db, files);
  final locks = FileLockManager();
  final importer = ImportService(
    files: files,
    metadata: metadata,
    artwork: artwork,
    tracks: tracks,
    artists: artists,
    albums: albums,
    genres: genres,
    locks: locks,
    db: db,
  );
  final player =
      PlaybackController(stateDir: files.databaseDir, tracksRepo: tracks);
  final downloader = DownloadEngine(
      downloads: DownloadRepository(db), files: files, importer: importer);

  final deps = AppDependencies(
    root: root,
    files: files,
    db: db,
    tracks: tracks,
    artists: artists,
    albums: albums,
    genres: genres,
    playlists: PlaylistRepository(db),
    settings: SettingsRepository(db),
    history: HistoryRepository(db),
    downloads: DownloadRepository(db),
    metadata: metadata,
    artwork: artwork,
    locks: locks,
    importer: importer,
    backup: BackupService(files: files, db: db),
    diagnostics: DiagnosticsService(files: files, db: db),
    player: player,
    downloader: downloader,
    // Constructor is cheap (setup is lazy); never used in this test.
    ytDlp: createYtDlpBackend(appRoot: root),
  );
  return ProviderContainer(
    overrides: [appDepsProvider.overrideWithValue(deps)],
  );
}

void main() {
  // Tests intentionally open several AppDatabase instances in one process.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('app theme constructs', () {
    expect(AppTheme.light, isA<ThemeData>());
    expect(AppTheme.dark, isA<ThemeData>());
  });

  test('data classes construct', () {
    final track = Track(
      id: '11111111-1111-1111-1111-111111111111',
      title: 'Test',
      artist: 'Artist',
      album: 'Album',
      durationMs: 123456,
      filePath: '/tmp/a.flac',
      fileFormat: 'flac',
      sourceType: 'local',
      playCount: 0,
      skipCount: 0,
      favorite: false,
      fileAvailability: FileAvailability.available,
      dateAdded: DateTime(2025),
      dateModified: DateTime(2025),
    );
    expect(track.title, 'Test');
    expect(track.fileAvailability, FileAvailability.available);
  });
  test('database boots, migrates and serves queries', () async {
    final container = await makeContainer();
    addTearDown(container.dispose);
    final deps = container.read(appDepsProvider);
    // Empty library queries must work end-to-end.
    expect(await deps.tracks.tracks(), isEmpty);
    expect(await deps.db.searchTracksIds('anything'), isEmpty);
    // Insert a track through the repository and verify FTS finds it.
    final added = await deps.tracks.upsert(Track(
      id: '33333333-3333-3333-3333-333333333333',
      title: 'Smoke Song',
      artist: 'Smoke Artist',
      album: 'Smoke Album',
      durationMs: 60000,
      filePath: '/tmp/smoke.flac',
      fileFormat: 'flac',
      sourceType: 'local',
      playCount: 0,
      skipCount: 0,
      favorite: false,
      fileAvailability: FileAvailability.available,
      dateAdded: DateTime(2025),
      dateModified: DateTime(2025),
    ));
    expect(added.title, 'Smoke Song');
    final hits = await deps.db.searchTracksIds('Smoke');
    expect(hits, contains(added.id));
  });

  testWidgets('track list tile renders', (tester) async {
    // Real I/O (temp dir + sqlite) must run outside the FakeAsync zone.
    final container = (await tester.runAsync(() => makeContainer()))!;
    addTearDown(container.dispose);
    final track = Track(
      id: '22222222-2222-2222-2222-222222222222',
      title: 'Track Title',
      artist: 'Some Artist',
      album: 'Some Album',
      durationMs: 210000,
      filePath: '/tmp/b.mp3',
      fileFormat: 'mp3',
      sourceType: 'local',
      playCount: 3,
      skipCount: 0,
      favorite: true,
      fileAvailability: FileAvailability.available,
      dateAdded: DateTime(2025),
      dateModified: DateTime(2025),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body:
                ListView(children: [TrackListTile(track: track, onTap: () {})]),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Track Title'), findsOneWidget);
    expect(find.textContaining('Some Artist'), findsOneWidget);
  });

  testWidgets('full app shell boots and renders', (tester) async {
    final container = (await tester.runAsync(() => makeContainer()))!;
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      // Pump the real app. The LibraryScreen's initial load performs a real
      // sqlite read; alternating real delays with pumps lets it complete.
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MusicPlayerApp(),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    expect(find.byType(MusicPlayerApp), findsOneWidget);
    expect(find.text('Library'), findsWidgets);
  });
}
