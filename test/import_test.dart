// M9 QA: end-to-end import pipeline against a real (synthesized) WAV file.
//  - file lands in the library with real extracted duration
//  - FTS search finds it
//  - re-importing the same file is detected as a duplicate
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:music_player/core/services/artwork_service.dart';
import 'package:music_player/core/services/file_lock_manager.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/core/services/metadata_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';

/// Minimal valid 16-bit PCM mono WAV (same synthesis the download tests use).
List<int> _wavBytes({int seconds = 1, int sampleRate = 44100}) {
  final byteRate = sampleRate * 2;
  final dataLen = seconds * byteRate;
  final b = BytesBuilder();
  void u32(int v) {
    b.addByte(v & 0xff);
    b.addByte((v >> 8) & 0xff);
    b.addByte((v >> 16) & 0xff);
    b.addByte((v >> 24) & 0xff);
  }

  void u16(int v) {
    b.addByte(v & 0xff);
    b.addByte((v >> 8) & 0xff);
  }

  void ascii(String s) => b.add(utf8.encode(s));
  ascii('RIFF');
  u32(36 + dataLen);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(byteRate);
  u16(2); // block align
  u16(16); // bits per sample
  ascii('data');
  u32(dataLen);
  b.add(Uint8List.fromList(List.generate(dataLen, (_) => 0)));
  return b.toBytes();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('import: real WAV lands in the library, is searchable, dedups on re-run',
      () async {
    final temp = await Directory.systemTemp.createTemp('import_test_');
    try {
      final files = FileService(temp.path);
      await files.ensureDirectories();
      final db = AppDatabase.withFile(
          File(p.join(files.databaseDir, 't.sqlite')));
      final tracks = TrackRepository(db);
      final metadata = MetadataService(binDir: files.binDir);
      final artwork = ArtworkService(db, files);
      final importer = ImportService(
        files: files,
        metadata: metadata,
        artwork: artwork,
        tracks: tracks,
        artists: ArtistRepository(db),
        albums: AlbumRepository(db),
        genres: GenreRepository(db),
        locks: FileLockManager(),
        db: db,
      );

      // Source file lives outside the library root.
      final srcDir = Directory(p.join(temp.path, 'src'));
      await srcDir.create(recursive: true);
      final src = File(p.join(srcDir.path, 'song.wav'));
      await src.writeAsBytes(_wavBytes(seconds: 1));

      final result = await importer.importPaths([src.path]);
      expect(result.errors, 0, reason: result.errorsList.join('; '));
      expect(result.added, 1);
      expect(result.duplicates, 0);

      final imported = await tracks.tracks();
      expect(imported, hasLength(1));
      expect(imported.first.title, 'song');
      // Duration extracted from the real WAV header (~1s).
      expect(imported.first.durationMs, inInclusiveRange(800, 1500));
      // File physically lives inside the library now.
      expect(await File(imported.first.filePath).exists(), isTrue);
      expect(imported.first.filePath, startsWith(files.root));

      // FTS search finds the new track.
      final hits = await db.searchTracksIds('song');
      expect(hits, contains(imported.first.id));

      // Importing the same source again is a duplicate, not a second copy.
      final again = await importer.importPaths([src.path]);
      expect(again.added, 0);
      expect(again.duplicates, 1);
      expect(await tracks.tracks(), hasLength(1));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('removeTrack: deletes record, syncs FTS, cleans orphans, deletes file',
      () async {
    final temp = await Directory.systemTemp.createTemp('import_test_');
    try {
      final files = FileService(temp.path);
      await files.ensureDirectories();
      final db = AppDatabase.withFile(
          File(p.join(files.databaseDir, 't.sqlite')));
      final tracks = TrackRepository(db);
      final artists = ArtistRepository(db);
      final importer = ImportService(
        files: files,
        metadata: MetadataService(binDir: files.binDir),
        artwork: ArtworkService(db, files),
        tracks: tracks,
        artists: artists,
        albums: AlbumRepository(db),
        genres: GenreRepository(db),
        locks: FileLockManager(),
        db: db,
      );
      final srcDir = Directory(p.join(temp.path, 'src'));
      await srcDir.create(recursive: true);
      final src = File(p.join(srcDir.path, 'gone.wav'));
      await src.writeAsBytes(_wavBytes());

      await importer.importPaths([src.path]);
      final imported = (await tracks.tracks()).single;
      final filePath = imported.filePath;
      expect(await artists.all(), isNotEmpty, reason: 'artist row should exist');

      await tracks.removeTrack(imported.id, deleteFile: true);

      expect(await tracks.tracks(), isEmpty);
      expect(await db.searchTracksIds('gone'), isEmpty,
          reason: 'FTS must not keep deleted tracks');
      // Orphan cleanup: no remaining tracks, so the artist row is gone.
      expect(await artists.all(), isEmpty);
      expect(await File(filePath).exists(), isFalse,
          reason: 'file should be deleted on disk');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('import: unsupported extension is reported as an error, not added',
      () async {
    final temp = await Directory.systemTemp.createTemp('import_test_');
    try {
      final files = FileService(temp.path);
      await files.ensureDirectories();
      final db = AppDatabase.withFile(
          File(p.join(files.databaseDir, 't.sqlite')));
      final tracks = TrackRepository(db);
      final importer = ImportService(
        files: files,
        metadata: MetadataService(binDir: files.binDir),
        artwork: ArtworkService(db, files),
        tracks: tracks,
        artists: ArtistRepository(db),
        albums: AlbumRepository(db),
        genres: GenreRepository(db),
        locks: FileLockManager(),
        db: db,
      );
      final src = File(p.join(temp.path, 'notes.txt'));
      await src.writeAsString('not audio');

      // Non-audio files are filtered out before import (silent skip).
      final result = await importer.importPaths([src.path]);
      expect(result.added, 0);
      expect(result.errors, 0);
      expect(result.duplicates, 0);
      expect(await tracks.tracks(), isEmpty);
      expect(await File(src.path).exists(), isTrue, reason: 'source untouched');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
