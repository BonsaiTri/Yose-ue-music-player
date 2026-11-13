import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/errors/app_exceptions.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';

/// Atomic, verified database + settings backups.
///
/// Workflow: write backup to a temp location (SQLite VACUUM INTO for a
/// consistent snapshot), generate a manifest, verify integrity, then finalize.
/// The previous valid backup is preserved until the new one is verified.
class BackupService {
  BackupService({required this.files, required this.db});

  final FileService files;
  final AppDatabase db;

  /// Creates a new verified backup. Returns its directory.
  Future<Directory> createBackup() async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r':|\.|T'), '-');
    final target = Directory(p.join(files.backupsDir, 'backup_$stamp'));
    final temp = Directory('${target.path}.tmp');
    try {
      await temp.create(recursive: true);
      final dbPath = p.join(temp.path, 'library.sqlite');
      // VACUUM INTO produces a consistent snapshot without file copying races.
      await db.customStatement("VACUUM INTO ?", [dbPath]);
      if (!await File(dbPath).exists() || await File(dbPath).length() == 0) {
        throw const StorageException('Backup snapshot is empty');
      }
      final manifest = {
        'version': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'database': 'library.sqlite',
      };
      await File(p.join(temp.path, 'manifest.json'))
          .writeAsString(jsonEncode(manifest));

      // Verify the snapshot opens and passes a quick integrity check.
      await _verifySnapshot(dbPath);

      // Finalize atomically; keep previous backups untouched.
      final old = Directory(target.path);
      if (await old.exists()) await old.delete(recursive: true);
      await temp.rename(target.path);
      AppLogger.info('Backup created: ${target.path}', tag: 'backup');
      return target;
    } catch (e) {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
      AppLogger.error('Backup failed: $e', tag: 'backup');
      throw StorageException('Backup failed', cause: e);
    }
  }

  Future<void> _verifySnapshot(String dbPath) async {
    final verify = AppDatabase.withFile(File(dbPath));
    try {
      final result =
          await verify.customSelect('PRAGMA quick_check').getSingle();
      final ok = result.read<String>('quick_check') == 'ok';
      if (!ok) throw StorageException('Backup snapshot failed quick_check');
    } finally {
      await verify.close();
    }
  }

  /// Lists existing backups, newest first.
  Future<List<Directory>> listBackups() async {
    final root = Directory(files.backupsDir);
    if (!await root.exists()) return const [];
    final dirs = await root
        .list()
        .where((e) => e is Directory && e.path.contains('backup_'))
        .cast<Directory>()
        .toList();
    dirs.sort((a, b) => b.path.compareTo(a.path));
    return dirs;
  }

  /// Restores the newest (or specified) backup over the live database file.
  /// The current database is preserved (moved aside) rather than deleted.
  Future<void> restoreLatest({Directory? backup}) async {
    final backups = await listBackups();
    if (backups.isEmpty) throw const StorageException('No backups available');
    final src = backup ?? backups.first;
    final srcDb = File(p.join(src.path, 'library.sqlite'));
    if (!await srcDb.exists())
      throw StorageException('Backup has no database file');
    await _verifySnapshot(srcDb.path);

    final live = File(_liveDbPath());
    if (await live.exists()) {
      final preserved = File(
          '${live.path}.pre_restore_${DateTime.now().millisecondsSinceEpoch}');
      await live.rename(preserved.path);
      AppLogger.info('Preserved live database as ${preserved.path}',
          tag: 'backup');
    }
    await srcDb.copy(_liveDbPath());
    AppLogger.info('Restored from ${src.path}', tag: 'backup');
  }

  /// Creates a backup when the newest one is older than [maxAge], then trims
  /// the store to the [keep] most recent backups. Never throws — this runs
  /// as a fire-and-forget task at startup and must not block boot.
  Future<void> autoBackupIfStale({
    Duration maxAge = const Duration(hours: 24),
    int keep = 5,
  }) async {
    try {
      final backups = await listBackups();
      final newest = backups.isEmpty ? null : await backups.first.stat();
      final stale =
          newest == null || DateTime.now().difference(newest.modified) > maxAge;
      if (stale) {
        final created = await createBackup();
        AppLogger.info('Automatic backup created: ${created.path}',
            tag: 'backup');
      }
      final all = await listBackups();
      for (final old in all.skip(keep)) {
        await old.delete(recursive: true);
        AppLogger.info('Pruned old backup: ${old.path}', tag: 'backup');
      }
    } catch (e) {
      // Non-fatal by design: a missed auto-backup is logged, not surfaced.
      AppLogger.warning('Auto-backup skipped: $e', tag: 'backup');
    }
  }

  String _liveDbPath() =>
      p.join(files.databaseDir, AppConstants.databaseFileName);
}
