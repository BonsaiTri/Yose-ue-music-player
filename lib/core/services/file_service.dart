import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/errors/app_exceptions.dart';
import 'package:music_player/core/logging/app_logger.dart';

/// Resolves all application storage locations and performs safe filesystem
/// operations.
///
/// All paths are derived from the platform application-data root; no
/// absolute paths are ever hardcoded.
class FileService {
  FileService(this.root);

  /// Application data root (platform-specific writable directory).
  final String root;

  String get databaseDir => p.join(root, AppConstants.dirDatabase);
  String get downloadsDir => p.join(root, AppConstants.dirDownloads);
  String get musicDir => p.join(root, AppConstants.dirMusic);
  String get artworkDir => p.join(root, AppConstants.dirArtwork);
  String get cacheDir => p.join(root, AppConstants.dirCache);
  String get binDir => p.join(root, AppConstants.dirBin);
  String get backupsDir => p.join(root, AppConstants.dirBackups);
  String get tempDir => p.join(root, AppConstants.dirTemp);

  /// Ensures the standard directory layout exists.
  Future<void> ensureDirectories() async {
    final dirs = [root, databaseDir, downloadsDir, musicDir, artworkDir, cacheDir, binDir, backupsDir, tempDir];
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
        AppLogger.info('Created directory $dir', tag: 'files');
      }
    }
  }

  bool isAudioFile(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return AppConstants.audioExtensions.contains(ext);
  }

  /// Renames [from] to [to] when on the same filesystem (atomic); otherwise
  /// copies, validates, then removes the source.
  Future<void> atomicMove(String from, String to) async {
    if (!await File(from).exists()) {
      throw FileOperationException('Cannot move missing file: $from');
    }
    try {
      // Dart's rename is a native rename(2): atomic on the same volume.
      await File(from).rename(to);
      return;
    } on FileSystemException catch (e) {
      // Cross-volume fallback: copy -> verify -> delete source.
      AppLogger.warning('Rename failed ($e); falling back to copy', tag: 'files');
      final src = File(from);
      final dst = File(to);
      final srcInfo = await src.stat();
      await dst.create(recursive: true);
      await src.copy(to);
      final dstInfo = await dst.stat();
      if (dstInfo.size != srcInfo.size) {
        try {
          await dst.delete();
        } catch (_) {}
        throw FileOperationException('Cross-volume copy failed size verification: $to');
      }
      await src.delete();
    }
  }

  /// Deletes a temporary file, ignoring already-missing files.
  Future<void> deleteTemp(String path) async {
    try {
      if (await File(path).exists()) {
        await File(path).delete();
      }
    } catch (e) {
      AppLogger.warning('Failed to delete temp file $path: $e', tag: 'files');
    }
  }

  /// Removes abandoned temporary files older than [olderThan] during startup
  /// recovery. Only files under the temp directory are touched.
  Future<int> cleanupAbandonedTemps({Duration olderThan = const Duration(hours: 1)}) async {
    final dir = Directory(tempDir);
    if (!await dir.exists()) return 0;
    final now = DateTime.now();
    var removed = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (now.difference(stat.modified) > olderThan) {
        await deleteTemp(entity.path);
        removed++;
      }
    }
    if (removed > 0) {
      AppLogger.info('Removed $removed abandoned temp file(s)', tag: 'files');
    }
    return removed;
  }

  /// Total size of all files under [dir] (non-recursive option).
  Future<int> directorySize(String dir, {bool recursive = true}) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: recursive, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// True when [dir] exists and is readable; used for external-drive checks.
  Future<bool> isDirectoryAccessible(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return false;
    try {
      await for (final _ in d.list().take(1)) {
        // Readable; an entry was visible.
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
