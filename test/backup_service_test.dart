// M5 reliability tests for BackupService.autoBackupIfStale:
//  - creates a backup when none exists
//  - skips when a recent backup exists
//  - prunes the store to the `keep` most recent backups
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:music_player/core/services/backup_service.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<({BackupService backup, Directory temp})> make() async {
    final temp = await Directory.systemTemp.createTemp('backup_test_');
    final files = FileService(temp.path);
    await files.ensureDirectories();
    final db =
        AppDatabase.withFile(File(p.join(files.databaseDir, 't.sqlite')));
    return (backup: BackupService(files: files, db: db), temp: temp);
  }

  test('creates a backup when none exists, skips when one is fresh', () async {
    final m = await make();
    try {
      final before = await m.backup.listBackups();
      expect(before, isEmpty);
      await m.backup.autoBackupIfStale();
      final after = await m.backup.listBackups();
      expect(after, hasLength(1));
      // Second run within 24h must be a no-op.
      await m.backup.autoBackupIfStale();
      expect(await m.backup.listBackups(), hasLength(1));
      // The snapshot must be a real, verified database.
      expect(File(p.join(after.first.path, 'library.sqlite')).existsSync(),
          isTrue);
    } finally {
      await m.temp.delete(recursive: true);
    }
  });

  test('prunes the store down to the keep most recent backups', () async {
    final m = await make();
    try {
      // Three stale-looking backups (names sort by embedded timestamp).
      for (final day in ['2020-01-01', '2020-01-02', '2020-01-03']) {
        await Directory(p.join(m.backup.files.backupsDir, 'backup_$day'))
            .create(recursive: true);
      }
      await m.backup.autoBackupIfStale(maxAge: Duration.zero, keep: 2);
      final remaining = await m.backup.listBackups();
      expect(remaining, hasLength(2));
      // The freshly created real backup (newest name) must survive,
      // along with the newest fake; the two oldest fakes are pruned.
      final names = remaining.map((d) => p.basename(d.path)).toList();
      expect(names, contains('backup_2020-01-03'));
      expect(names, isNot(contains('backup_2020-01-01')));
      expect(names, isNot(contains('backup_2020-01-02')));
    } finally {
      await m.temp.delete(recursive: true);
    }
  });

  test('autoBackupIfStale never throws, even with a broken store', () async {
    final m = await make();
    try {
      // Corrupt the backups dir into a file so listBackups/list hit I/O errors.
      final backupsDir = Directory(m.backup.files.backupsDir);
      await backupsDir.delete(recursive: true);
      await File(backupsDir.path).writeAsString('not a dir');
      await m.backup.autoBackupIfStale(); // must not throw
      // Clean up and confirm the service recovers on the next run.
      await File(backupsDir.path).delete();
      await backupsDir.create();
      await m.backup.autoBackupIfStale(keep: 5);
      expect(await m.backup.listBackups(), hasLength(1));
    } finally {
      await m.temp.delete(recursive: true);
    }
  });
}
