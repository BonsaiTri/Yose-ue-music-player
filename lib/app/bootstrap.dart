import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/platform/platform_info.dart';
import 'package:music_player/core/services/artwork_service.dart';
import 'package:music_player/core/services/backup_service.dart';
import 'package:music_player/core/services/binary_manager.dart';
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
import 'package:music_player/features/search/domain/search_provider.dart';
import 'package:path_provider/path_provider.dart';

/// All long-lived singletons, created once during bootstrap and shared
/// through Riverpod overrides.
class AppDependencies {
  AppDependencies({
    required this.root,
    required this.files,
    required this.db,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.genres,
    required this.playlists,
    required this.settings,
    required this.history,
    required this.downloads,
    required this.metadata,
    required this.artwork,
    required this.locks,
    required this.importer,
    required this.backup,
    required this.diagnostics,
    required this.player,
    required this.downloader,
    required this.ytDlp,
    this.sources = const SearchProviderRegistry(const []),
  });

  final String root;
  final FileService files;
  final AppDatabase db;
  final TrackRepository tracks;
  final ArtistRepository artists;
  final AlbumRepository albums;
  final GenreRepository genres;
  final PlaylistRepository playlists;
  final SettingsRepository settings;
  final HistoryRepository history;
  final DownloadRepository downloads;
  final MetadataService metadata;
  final ArtworkService artwork;
  final FileLockManager locks;
  final ImportService importer;
  final BackupService backup;
  final DiagnosticsService diagnostics;
  final PlaybackController player;
  final DownloadEngine downloader;
  final YtDlpBackend ytDlp;

  /// Registered external music sources (spec §6.5). Empty by default —
  /// local-only search; providers are enabled at bootstrap.
  final SearchProviderRegistry sources;
}

final appDepsProvider = Provider<AppDependencies>((ref) {
  throw StateError('AppDependencies must be overridden during bootstrap');
});

final dbProvider =
    Provider<AppDatabase>((ref) => ref.watch(appDepsProvider).db);
final fileServiceProvider =
    Provider<FileService>((ref) => ref.watch(appDepsProvider).files);
final playerProvider =
    Provider<PlaybackController>((ref) => ref.watch(appDepsProvider).player);

/// File-level database recovery (M8): quarantines the current database file
/// (plus any stale WAL/SHM sidecars) and restores the newest backup snapshot
/// over it. When no backup exists the database is simply quarantined and the
/// next bootstrap creates a fresh one.
///
/// Returns a human-readable description of what was done, or null when there
/// was nothing to recover.
Future<String?> recoverDatabase() async =>
    recoverDatabaseAt(await resolveAppRoot());

/// File-level recovery against an explicit data root (testable without
/// platform channels).
Future<String?> recoverDatabaseAt(String root) async {
  final files = FileService(root);
  await files.ensureDirectories();
  final live = File(p.join(files.databaseDir, AppConstants.databaseFileName));
  if (!await live.exists()) return null;

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final quarantine = File('${live.path}.corrupt_$stamp');
  await live.rename(quarantine.path);
  // Stale sidecars from the corrupt database must not survive the swap.
  for (final sidecar in ['-wal', '-shm']) {
    final f = File(live.path + sidecar);
    if (await f.exists()) await f.delete();
  }

  // File-level listing: the backup store is plain directories, no DB needed.
  final backupsDir = Directory(files.backupsDir);
  List<Directory> backups = const [];
  if (await backupsDir.exists()) {
    backups = await backupsDir
        .list()
        .where((e) => e is Directory && e.path.contains('backup_'))
        .cast<Directory>()
        .toList();
    backups.sort((a, b) => b.path.compareTo(a.path));
  }
  if (backups.isEmpty) {
    AppLogger.warning('Recovery: quarantined corrupt database, starting fresh', tag: 'recovery');
    return 'The database file was moved to ${quarantine.path}. ' 'Starting with a fresh library.';
  }
  final src = File(p.join(backups.first.path, 'library.sqlite'));
  if (!await src.exists()) {
    AppLogger.warning('Newest backup has no database file; starting fresh', tag: 'recovery');
    return 'The newest backup was unusable; starting with a fresh library.';
  }
  await src.copy(live.path);
  AppLogger.info('Recovery: restored database from ${backups.first.path}', tag: 'recovery');
  return 'Restored the library from the newest backup (${p.basename(backups.first.path)}). ' 'The corrupt file is kept at ${quarantine.path}.';
}

/// The platform default application-data root (no hardcoded absolute paths).
Future<String> defaultAppRoot() async {
  try {
    return (await getApplicationSupportDirectory()).path;
  } catch (_) {
    return (await getApplicationDocumentsDirectory()).path;
  }
}

/// Resolves the platform application-data root (no hardcoded absolute paths).
///
/// If the user previously chose a custom data location (spec §6.10/§6.8),
/// the choice is persisted in the default-root database and honored here.
/// Safety net: a custom location only counts when it actually contains a
/// database. A bare directory (e.g. a location changed without migrating,
/// or an Android folder whose permission did not survive a restart) falls
/// back to the default root instead of opening a silently-empty library.
Future<String> resolveAppRoot() async => resolveAppRootAt(await defaultAppRoot());

/// Testable variant of [resolveAppRoot] with an explicit default root.
Future<String> resolveAppRootAt(String defaultRoot) async {
  try {
    final probe = AppDatabase.withFile(File(p.join(
        defaultRoot, AppConstants.dirDatabase, AppConstants.databaseFileName)));
    try {
      final stored = await SettingsRepository(probe).get('storage.root');
      if (stored != null && stored.isNotEmpty && stored != defaultRoot) {
        final customDb = File(p.join(
            stored, AppConstants.dirDatabase, AppConstants.databaseFileName));
        if (customDb.existsSync()) {
          AppLogger.info('Using custom data location: $stored', tag: 'bootstrap');
          return stored;
        }
        AppLogger.warning(
            'Custom data location "$stored" has no database; '
            'falling back to the default root',
            tag: 'bootstrap');
      }
    } finally {
      await probe.close();
    }
  } catch (_) {
    // Default-root database absent or unreadable; use the default root.
  }
  return defaultRoot;
}

/// Boots storage, database, recovery and all singletons.
Future<ProviderContainer> bootstrap() async {
  AppLogger.info('Bootstrap started', tag: 'bootstrap');
  final root = await resolveAppRoot();
  final files = FileService(root);
  await files.ensureDirectories();

  final dbFile = File(p.join(files.databaseDir, AppConstants.databaseFileName));
  final db = AppDatabase.withFile(dbFile);
  AppLogger.info('Database opened: ${dbFile.path}', tag: 'bootstrap');

  // Startup recovery (spec 17.9): clean abandoned temp files and recover
  // interrupted download tasks (persisted state must not sit in limbo).
  await files.cleanupAbandonedTemps();
  final downloads = DownloadRepository(db);
  final interrupted = await (db.select(db.downloadTasks)
        ..where((t) => t.status.isInValues([
              DownloadTaskStatus.preparing,
              DownloadTaskStatus.downloading,
              DownloadTaskStatus.processing,
              DownloadTaskStatus.validating,
            ])))
      .get();
  for (final task in interrupted) {
    await downloads.updateStatus(task.id, DownloadTaskStatus.failed,
        error: 'Interrupted by application exit at ${task.updatedAt}');
    AppLogger.info(
        'Recovered interrupted download ${task.id} -> FAILED (retryable)',
        tag: 'recovery');
  }

  // Automatic backup (M5): top up if the newest backup is >24h old and prune
  // old ones. Fire-and-forget so it never blocks boot; failures are logged.
  final backup = BackupService(files: files, db: db);
  unawaited(backup.autoBackupIfStale());

  final metadata = MetadataService(binDir: files.binDir);
  final locks = FileLockManager();
  final artwork = ArtworkService(db, files);
  final tracks = TrackRepository(db);
  final artists = ArtistRepository(db);
  final albums = AlbumRepository(db);
  final genres = GenreRepository(db);
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
  final player = PlaybackController(
    stateDir: files.databaseDir,
    tracksRepo: tracks,
    artworkPathFor: artwork.absolutePathFor,
  );
  await player.init();
  await player.restore();

  final settings = SettingsRepository(db);
  // Spec §6.10: user-configurable queue limit (applied at startup).
  final maxConcurrent = (int.tryParse(await settings.get('downloads.maxConcurrent') ?? '')
          ?? AppConstants.maxConcurrentDownloads)
      .clamp(1, 10);
  // YouTube downloads run through yt-dlp (bundled on Android, pinned
  // official binary on desktop). Setup is lazy: first YouTube action.
  final ytDlp = createYtDlpBackend(appRoot: root);
  final playlists = PlaylistRepository(db);
  final downloader = DownloadEngine(
    downloads: downloads,
    files: files,
    importer: importer,
    concurrency: maxConcurrent,
    ytDlp: ytDlp,
    playlists: playlists,
  );
  await downloader.start();

  final deps = AppDependencies(
    root: root,
    files: files,
    db: db,
    tracks: tracks,
    artists: artists,
    albums: albums,
    genres: genres,
    playlists: playlists,
    settings: settings,
    history: HistoryRepository(db),
    downloads: downloads,
    metadata: metadata,
    artwork: artwork,
    locks: locks,
    importer: importer,
    backup: backup,
    ytDlp: ytDlp,
    diagnostics: DiagnosticsService(files: files, db: db),
    player: player,
    downloader: downloader,
  );

  // Desktop binary validation (no-op guarded on mobile).
  if (PlatformInfo.isDesktop) {
    final binary = BinaryManager(binDir: files.binDir, assetsRoot: root);
    final statuses = await binary.ensureDependencies();
    for (final s in statuses) {
      AppLogger.info(
          'Binary status: ${s.os}/${s.arch} available=${s.available} ${s.notes ?? ''}',
          tag: 'binary');
    }
  }

  AppLogger.info('Bootstrap complete', tag: 'bootstrap');
  return ProviderContainer(
    overrides: [appDepsProvider.overrideWithValue(deps)],
  );
}
