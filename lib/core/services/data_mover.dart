import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';

/// Migrates the complete data tree from one root to another so that
/// changing the data location moves the library instead of orphaning it.
///
/// Guarantees:
/// * The source tree is never modified or deleted.
/// * The database is copied as a consistent snapshot (VACUUM INTO from the
///   live connection — no cross-connection lock races).
/// * Any failure removes the destination tree (rollback) and rethrows, so
///   the running app keeps working on the original root.
class DataMover {
  const DataMover();

  /// Data-bearing subdirectories carried across the move. The `bin` and
  /// `tmp` directories are deliberately excluded (rebuildable / transient).
  static const List<String> migratedDirs = [
    AppConstants.dirMusic,
    AppConstants.dirArtwork,
    AppConstants.dirDownloads,
    AppConstants.dirBackups,
    AppConstants.dirCache,
  ];

  /// Copies [from] into [to] (database + [migratedDirs]), verifies the copy,
  /// and persists the new choice in the default-root database.
  ///
  /// [db] is the live application database (used for a consistent snapshot);
  /// it must belong to [from]. [defaultRoot] is where [resolveAppRoot]
  /// probes for the persisted choice, so the setting is always written there.
  Future<void> migrate({
    required AppDatabase db,
    required String from,
    required String to,
    required String defaultRoot,
    void Function(int doneBytes, int totalBytes)? onProgress,
  }) async {
    if (p.equals(from, to)) {
      throw const DataMoverException('Source and destination are the same location');
    }
    if (!Directory(from).existsSync()) {
      throw DataMoverException('Source does not exist: $from');
    }
    final toDir = Directory(to);
    AppLogger.info('Migration starting: $from -> $to', tag: 'migrate');
    try {
      toDir.createSync(recursive: true);
      await _copyDatabase(db, to);
      var grandDone = 0;
      var grandTotal = 0;
      for (final name in migratedDirs) {
        final src = Directory(p.join(from, name));
        if (!src.existsSync()) continue;
        final (done, total) =
            await _copyTree(src, Directory(p.join(to, name)), onProgress);
        grandDone += done;
        grandTotal += total;
      }
      _verifySize(from, to);
      await _persistChoice(to, defaultRoot);
      AppLogger.info(
          'Migration complete (${grandDone} bytes moved, setting persisted)', tag: 'migrate');
    } catch (e) {
      AppLogger.error('Migration failed, rolling back destination: $e', tag: 'migrate');
      try {
        toDir.deleteSync(recursive: true);
      } catch (_) {}
      if (e is DataMoverException) rethrow;
      throw DataMoverException('$e');
    }
  }

  /// VACUUM INTO writes a consistent snapshot of the live database to the
  /// destination. A stale copy from a previous failed attempt is replaced.
  Future<void> _copyDatabase(AppDatabase db, String to) async {
    final dst = File(p.join(to, AppConstants.dirDatabase, AppConstants.databaseFileName));
    if (dst.existsSync()) dst.deleteSync();
    dst.parent.createSync(recursive: true);
    final target = dst.path.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$target'");
    if (!dst.existsSync() || dst.lengthSync() == 0) {
      throw DataMoverException('Database snapshot failed at ${dst.path}');
    }
  }

  /// Recursively copies [src] into [dst], reporting byte progress.
  Future<(int, int)> _copyTree(
    Directory src,
    Directory dst,
    void Function(int, int)? onProgress,
  ) async {
    dst.createSync(recursive: true);
    final files = <File>[];
    final dirs = <Directory>[];
    void walk(Directory d) {
      for (final entity in d.listSync(followLinks: false)) {
        if (entity is Directory) {
          dirs.add(entity);
          walk(entity);
        } else if (entity is File) {
          files.add(entity);
        }
      }
    }
    walk(src);

    var total = 0;
    for (final f in files) {
      total += f.lengthSync();
    }
    var done = 0;
    for (final dir in dirs) {
      final rel = p.relative(dir.path, from: src.path);
      Directory(p.join(dst.path, rel)).createSync(recursive: true);
    }
    for (final file in files) {
      final rel = p.relative(file.path, from: src.path);
      final target = File(p.join(dst.path, rel));
      target.parent.createSync(recursive: true);
      await file.copy(target.path);
      done += file.lengthSync();
      onProgress?.call(done, total);
    }
    return (done, total);
  }

  /// The destination must contain exactly as many bytes as the source in the
  /// migrated directories (files were copied individually, so a size
  /// mismatch means a silent failure).
  void _verifySize(String from, String to) {
    int sumOf(String root) {
      var total = 0;
      for (final name in migratedDirs) {
        final d = Directory(p.join(root, name));
        if (!d.existsSync()) continue;
        for (final entity in d.listSync(recursive: true, followLinks: false)) {
          if (entity is File) total += entity.lengthSync();
        }
      }
      return total;
    }
    final a = sumOf(from);
    final b = sumOf(to);
    if (a != b) {
      throw DataMoverException('Size mismatch after copy ($a source vs $b destination)');
    }
  }

  /// Writes the choice where resolveAppRoot() probes: the default-root
  /// database (a second connection is fine while the app runs on its own).
  Future<void> _persistChoice(String to, String defaultRoot) async {
    final dbFile = File(p.join(defaultRoot, AppConstants.dirDatabase, AppConstants.databaseFileName));
    if (!dbFile.existsSync()) {
      throw DataMoverException('Default-root database missing at ${dbFile.path}');
    }
    final probe = AppDatabase.withFile(dbFile);
    try {
      await SettingsRepository(probe).set('storage.root', to);
    } finally {
      await probe.close();
    }
  }
}

class DataMoverException implements Exception {
  const DataMoverException(this.message);
  final String message;
  @override
  String toString() => 'DataMoverException: $message';
}
