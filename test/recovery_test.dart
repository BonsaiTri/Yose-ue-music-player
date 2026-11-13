// M8 recovery tests for recoverDatabaseAt:
//  - missing database file -> nothing to recover
//  - corrupt database + no backup -> quarantined, fresh start
//  - corrupt database + backup -> latest snapshot restored over the live file
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/services/file_service.dart';

void main() {
  Future<Directory> makeRoot() async {
    final temp = await Directory.systemTemp.createTemp('recovery_test_');
    final files = FileService(temp.path);
    await files.ensureDirectories();
    return temp;
  }

  test('missing database file means nothing to recover', () async {
    final temp = await makeRoot();
    try {
      expect(await recoverDatabaseAt(temp.path), isNull);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('corrupt database with no backup is quarantined for a fresh start',
      () async {
    final temp = await makeRoot();
    try {
      final files = FileService(temp.path);
      final live = File(p.join(files.databaseDir, AppConstants.databaseFileName));
      await live.writeAsString('not a sqlite file');
      await File('${live.path}-wal').writeAsString('stale wal');

      final message = await recoverDatabaseAt(temp.path);
      expect(message, isNotNull);
      expect(await live.exists(), isFalse);
      expect(await File('${live.path}-wal').exists(), isFalse);
      // A quarantined copy exists alongside.
      final dir = Directory(files.databaseDir).listSync();
      expect(
          dir.any((e) => e.path.contains('.corrupt_')), isTrue,
          reason: 'quarantined file should exist');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('corrupt database with a backup restores the newest snapshot', () async {
    final temp = await makeRoot();
    try {
      final files = FileService(temp.path);
      final live = File(p.join(files.databaseDir, AppConstants.databaseFileName));
      await live.writeAsString('corrupted bytes');

      // Two fake backups; names sort by embedded timestamp.
      final old = Directory(p.join(files.backupsDir, 'backup_2020-01-01'));
      final new_ = Directory(p.join(files.backupsDir, 'backup_2021-01-01'));
      await old.create(recursive: true);
      await new_.create(recursive: true);
      await File(p.join(old.path, 'library.sqlite')).writeAsString('old db');
      await File(p.join(new_.path, 'library.sqlite')).writeAsString('new db');

      final message = await recoverDatabaseAt(temp.path);
      expect(message, contains('newest backup'));
      expect(await live.readAsString(), 'new db');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
