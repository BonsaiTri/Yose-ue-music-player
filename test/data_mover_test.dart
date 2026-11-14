// DataMover + resolveAppRootAt tests:
//  - custom location without a database falls back to the default root
//  - custom location with a database is honored
//  - migration moves the database (consistent snapshot) and all data,
//    persists the choice in the default-root database, and keeps the source
//  - failed migration rolls back the destination and leaves the source intact
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/services/data_mover.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';
import 'package:music_player/database/tables/tables.dart';

Future<Directory> makeRoot(String name) async {
  final temp = await Directory.systemTemp.createTemp(name);
  await FileService(temp.path).ensureDirectories();
  return temp;
}

AppDatabase openDb(Directory root) =>
    AppDatabase.withFile(File(p.join(
        root.path, AppConstants.dirDatabase, AppConstants.databaseFileName)));

void main() {
  test('custom location without a database falls back to the default root',
      () async {
    final def = await makeRoot('resolve_def_');
    final custom = await Directory.systemTemp.createTemp('resolve_custom_');
    try {
      final db = await openDb(def);
      try {
        await SettingsRepository(db).set('storage.root', custom.path);
        // Custom root is a bare directory: no database there.
        expect(await resolveAppRootAt(def.path), def.path);
      } finally {
        await db.close();
      }
    } finally {
      await def.delete(recursive: true);
      await custom.delete(recursive: true);
    }
  });

  test('nonexistent custom location falls back to the default root',
      () async {
    final def = await makeRoot('resolve_gone_');
    final missing = p.join(def.path, 'does_not_exist');
    try {
      final db = await openDb(def);
      try {
        await SettingsRepository(db).set('storage.root', missing);
        expect(await resolveAppRootAt(def.path), def.path);
      } finally {
        await db.close();
      }
    } finally {
      await def.delete(recursive: true);
    }
  });

  test('custom location with a database is honored', () async {
    final def = await makeRoot('resolve_honor_');
    final custom = await makeRoot('resolve_honor_custom_');
    try {
      final db = await openDb(def);
      final customDb = openDb(custom);
      try {
        // Force the file to exist (Drift creates it on first use).
        await customDb.customStatement('SELECT 1');
        await SettingsRepository(db).set('storage.root', custom.path);
        expect(await resolveAppRootAt(def.path), custom.path);
      } finally {
        await customDb.close();
        await db.close();
      }
    } finally {
      await def.delete(recursive: true);
      await custom.delete(recursive: true);
    }
  });

  test('migration moves database and data and persists the choice', () async {
    final def = await makeRoot('migrate_ok_');
    final to = await Directory.systemTemp.createTemp('migrate_ok_to_');
    try {
      final db = await openDb(def);
      try {
        final now = DateTime(2026);
        await SettingsRepository(db).set('theme.mode', 'dark');
        await TrackRepository(db).upsert(Track(
          id: 't1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Unknown Album',
          durationMs: 0,
          filePath: p.join(def.path, AppConstants.dirMusic, 'a.mp3'),
          fileFormat: 'mp3',
          dateAdded: now,
          dateModified: now,
          sourceType: 'local',
          playCount: 0,
          skipCount: 0,
          favorite: false,
          fileAvailability: FileAvailability.available,
        ));
        final file = File(p.join(def.path, AppConstants.dirMusic, 'a.mp3'));
        await file.writeAsBytes(List.filled(1024, 1));

        await const DataMover().migrate(
          db: db,
          from: def.path,
          to: to.path,
          defaultRoot: def.path,
        );

        // Choice persisted in the default-root database.
        expect(await SettingsRepository(db).get('storage.root'), to.path);

        // Destination database is a consistent, openable snapshot.
        final db2 = await openDb(to);
        try {
          final tracks = await db2.select(db2.tracks).get();
          expect(tracks, hasLength(1));
          expect(tracks.single.title, 'Test Song');
          expect(await SettingsRepository(db2).get('theme.mode'), 'dark');
        } finally {
          await db2.close();
        }

        // Data files copied; source untouched.
        expect(
            await File(p.join(to.path, AppConstants.dirMusic, 'a.mp3'))
                .length(),
            1024);
        expect(await file.length(), 1024);
      } finally {
        await db.close();
      }
    } finally {
      await def.delete(recursive: true);
      await to.delete(recursive: true);
    }
  });

  test('failed migration rolls back destination and leaves source intact',
      () async {
    final def = await makeRoot('migrate_fail_');
    // Destination must be created inside a regular file: guaranteed failure.
    final blocker = File(
        '${Directory.systemTemp.path}/migrate_blocker_${DateTime.now().millisecondsSinceEpoch}');
    await blocker.create();
    final toPath = p.join(blocker.path, 'sub');
    try {
      final db = await openDb(def);
      try {
        final file = File(p.join(def.path, AppConstants.dirMusic, 'a.mp3'));
        await file.writeAsBytes(List.filled(512, 2));

        Object? caught;
        try {
          await const DataMover().migrate(
            db: db,
            from: def.path,
            to: toPath,
            defaultRoot: def.path,
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<DataMoverException>());
        // Destination rolled back (never created), source untouched.
        expect(await Directory(toPath).exists(), isFalse);
        expect(await file.length(), 512);
        expect(await SettingsRepository(db).get('storage.root'), isNull);
      } finally {
        await db.close();
      }
    } finally {
      await def.delete(recursive: true);
      await blocker.delete();
    }
  });
}
