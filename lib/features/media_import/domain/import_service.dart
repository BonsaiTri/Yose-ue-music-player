import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:music_player/core/services/artwork_service.dart';
import 'package:music_player/core/services/file_lock_manager.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/core/services/metadata_service.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';

final _uuid = Uuid();

/// Progress callback: (done, total, currentPath).
typedef ImportProgress = void Function(int done, int total, String current);

class ImportResult {
  const ImportResult({this.added = 0, this.duplicates = 0, this.errors = 0, this.errorsList = const []});
  final int added;
  final int duplicates;
  final int errors;
  final List<String> errorsList;
}

/// Single shared indexing pipeline used by every import method
/// (file picker, folder scan, drag-and-drop, external drives, downloads).
class ImportService {
  ImportService({
    required this.files,
    required this.metadata,
    required this.artwork,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.genres,
    required this.locks,
    required this.db,
  });

  final FileService files;
  final MetadataService metadata;
  final ArtworkService artwork;
  final TrackRepository tracks;
  final ArtistRepository artists;
  final AlbumRepository albums;
  final GenreRepository genres;
  final FileLockManager locks;
  final AppDatabase db;

  /// Imports a mixed list of files and directories.
  Future<ImportResult> importPaths(List<String> paths, {ImportProgress? onProgress}) async {
    // Spec §7 (Android): ask for media-read permission before touching files
    // outside the app sandbox. Desktop platforms need nothing.
    await _ensureReadPermission();
    final audioFiles = <String>[];
    for (final path in paths) {
      final isDir = Directory(path).existsSync();
      if (isDir) {
        audioFiles.addAll(await scanDirectory(path));
      } else if (File(path).existsSync() && files.isAudioFile(path)) {
        audioFiles.add(path);
      }
    }
    return importFiles(audioFiles, onProgress: onProgress);
  }

  /// Requests the Android storage permission once per import run.
  /// Denial is logged, not fatal; no-op on non-Android platforms.
  Future<void> _ensureReadPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.storage.request();
      if (!status.isGranted && !status.isPermanentlyDenied) {
        AppLogger.warning('Storage permission not granted; import may fail',
            tag: 'import');
      }
    } catch (e) {
      AppLogger.warning('Permission request failed: $e', tag: 'import');
    }
  }

  Future<List<String>> scanDirectory(String dir) async {
    final result = <String>[];
    await for (final entity in Directory(dir).list(recursive: true, followLinks: false)) {
      if (entity is File && files.isAudioFile(entity.path)) {
        result.add(entity.path);
      }
    }
    return result;
  }

  Future<ImportResult> importFiles(List<String> files, {ImportProgress? onProgress}) async {
    var added = 0;
    var duplicates = 0;
    var errors = 0;
    final errorList = <String>[];
    final pending = <Track>[];

    for (var i = 0; i < files.length; i++) {
      final path = files[i];
      onProgress?.call(i, files.length, path);
      try {
        await locks.acquireShared(path, 'indexer');
        try {
          final hash = await metadata.fileHash(path);
          final dup = await tracks.findDuplicate(contentHash: hash, sourceId: null);
          if (dup != null) {
            duplicates++;
            continue;
          }
          final meta = await metadata.extract(path);

          String? artworkId;
          if (meta.artworkBytes != null && meta.artworkBytes!.isNotEmpty) {
            try {
              final record = await artwork.store(
                bytes: meta.artworkBytes!,
                mime: meta.artworkMime ?? 'image/jpeg',
                category: 'albums',
              );
              artworkId = record.id;
            } catch (e) {
              AppLogger.warning('Artwork store failed for $path: $e', tag: 'import');
            }
          }

          final artistName = meta.artist ?? _artistFromPath(path);
          final artist = await artists.upsertByName(artistName);
          String? albumId;
          final albumTitle = meta.album;
          if (albumTitle != null) {
            final album = await albums.upsert(
              title: albumTitle,
              artistId: artist.id,
              albumArtist: meta.albumArtist,
              releaseYear: meta.releaseYear,
              genre: meta.genre,
              artworkRef: artworkId,
            );
            albumId = album.id;
          }
          String? genreId;
          if (meta.genre != null) {
            genreId = (await genres.upsertByName(meta.genre!)).id;
          }

          pending.add(Track(
            id: _uuid.v4(),
            title: meta.title ?? p.basenameWithoutExtension(path),
            artist: artistName,
            artistId: artist.id,
            album: albumTitle ?? 'Unknown Album',
            albumId: albumId,
            albumArtist: meta.albumArtist,
            genreId: genreId,
            genre: meta.genre,
            releaseYear: meta.releaseYear,
            durationMs: meta.durationMs,
            trackNumber: meta.trackNumber,
            discNumber: meta.discNumber,
            filePath: path,
            fileFormat: meta.format,
            fileSize: await File(path).length(),
            bitrate: meta.bitrate,
            sampleRate: meta.sampleRate,
            channels: meta.channels,
            artworkRef: artworkId,
            contentHash: hash,
            favorite: false,
            fileAvailability: FileAvailability.available,
            playCount: 0,
            skipCount: 0,
            sourceType: 'local',
            dateAdded: DateTime.now(),
            dateModified: DateTime.now(),
          ));
          added++;
        } finally {
          await locks.releaseShared(path);
        }
      } catch (e) {
        errors++;
        errorList.add('$path: $e');
        AppLogger.error('Import failed for $path: $e', tag: 'import');
      }
      onProgress?.call(i + 1, files.length, path);
    }

    if (pending.isNotEmpty) {
      await tracks.bulkRegister(pending);
    }
    AppLogger.info(
        'Import finished: $added added, $duplicates duplicates, $errors errors', tag: 'import');
    return ImportResult(added: added, duplicates: duplicates, errors: errors, errorsList: errorList);
  }

  /// Registers an already-downloaded file into the library (atomic import).
  ///
  /// Downloaded files (e.g. YouTube audio via yt-dlp) frequently carry no
  /// embedded metadata or artwork. Callers may supply overrides collected
  /// from the source (title, artist/channel, thumbnail bytes); embedded
  /// values win when present, otherwise the overrides are used.
  Future<Track?> registerDownloadedFile(
    String path, {
    String? sourceId,
    String? sourceType,
    String? titleOverride,
    String? artistOverride,
    List<int>? artworkBytes,
    String? artworkMime,
  }) async {
    if (!File(path).existsSync() || !files.isAudioFile(path)) return null;
    await locks.acquireShared(path, 'indexer');
    try {
      final hash = await metadata.fileHash(path);
      final meta = await metadata.extract(path);
      String? artworkId;
      final embeddedArt = (meta.artworkBytes != null && meta.artworkBytes!.isNotEmpty)
          ? meta.artworkBytes!
          : null;
      final artSource = embeddedArt ??
          ((artworkBytes != null && artworkBytes.isNotEmpty) ? artworkBytes : null);
      if (artSource != null) {
        try {
          artworkId = (await artwork.store(
            bytes: artSource,
            mime: embeddedArt != null ? (meta.artworkMime ?? 'image/jpeg') : (artworkMime ?? 'image/jpeg'),
            category: 'albums',
          )).id;
        } catch (_) {}
      }
      final metaArtist = (meta.artist != null && meta.artist!.trim().isNotEmpty)
          ? meta.artist
          : null;
      final artistName = metaArtist ??
          ((artistOverride != null && artistOverride.trim().isNotEmpty)
              ? artistOverride
              : 'Unknown Artist');
      final metaTitle = (meta.title != null && meta.title!.trim().isNotEmpty) ? meta.title : null;
      final artist = await artists.upsertByName(artistName);
      String? albumId;
      if (meta.album != null) {
        albumId = (await albums.upsert(
          title: meta.album!,
          artistId: artist.id,
          albumArtist: meta.albumArtist,
          releaseYear: meta.releaseYear,
          genre: meta.genre,
          artworkRef: artworkId,
        )).id;
      }
      String? genreId;
      if (meta.genre != null) genreId = (await genres.upsertByName(meta.genre!)).id;
      final track = Track(
        id: _uuid.v4(),
        title: metaTitle ??
            ((titleOverride != null && titleOverride.trim().isNotEmpty)
                ? titleOverride
                : p.basenameWithoutExtension(path)),
        artist: artistName,
        artistId: artist.id,
        album: meta.album ?? 'Unknown Album',
        albumId: albumId,
        albumArtist: meta.albumArtist,
        genreId: genreId,
        genre: meta.genre,
        releaseYear: meta.releaseYear,
        durationMs: meta.durationMs,
        trackNumber: meta.trackNumber,
        discNumber: meta.discNumber,
        filePath: path,
        fileFormat: meta.format,
        fileSize: await File(path).length(),
        bitrate: meta.bitrate,
        sampleRate: meta.sampleRate,
        channels: meta.channels,
        artworkRef: artworkId,
        sourceId: sourceId,
        sourceType: sourceType ?? 'download',
        contentHash: hash,
        favorite: false,
        fileAvailability: FileAvailability.available,
        playCount: 0,
        skipCount: 0,
        dateAdded: DateTime.now(),
        dateModified: DateTime.now(),
      );
      await tracks.upsert(track);
      return track;
    } finally {
      await locks.releaseShared(path);
    }
  }

  String _artistFromPath(String path) {
    final parts = p.split(p.dirname(path));
    if (parts.length >= 2) return parts[parts.length - 2];
    return 'Unknown Artist';
  }
}
