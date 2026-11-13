import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:music_player/database/database.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/services/file_service.dart';

/// Handles the artwork pipeline:
/// detection -> validation -> dimensions -> hash -> dedup -> cache storage ->
/// database reference registration.
///
/// Artwork is stored as separate files with hash-based names; the database
/// only holds relative references.
class ArtworkService {
  ArtworkService(this.db, this.files);

  final AppDatabase db;
  final FileService files;

  /// In-memory artworkId -> absolute path cache (negative results included)
  /// so scrolling a long list does not issue one PK query per tile per build.
  final Map<String, String?> _pathCache = {};

  /// Stores artwork bytes and returns the artwork record.
  /// Returns the existing record when identical artwork is already stored.
  Future<ArtworkData> store({
    required List<int> bytes,
    required String mime,
    required String category, // 'albums' | 'artists' | 'thumbnails'
  }) async {
    final hash = sha256.convert(bytes).toString();
    final existing = await (db.select(db.artwork)..where((a) => a.contentHash.equals(hash))).getSingleOrNull();
    if (existing != null) return existing;

    final byteData = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final image = img.decodeImage(byteData);
    if (image == null) {
      AppLogger.warning('Artwork bytes could not be decoded; skipping', tag: 'artwork');
      throw const _ArtworkInvalid();
    }

    final dir = p.join(files.artworkDir, category);
    Directory(dir).createSync(recursive: true);
    final ext = _extForMime(mime);
    final relativePath = 'Artwork/$category/$hash$ext';
    final path = p.join(files.root, relativePath);
    await File(path).writeAsBytes(bytes, flush: true);

    final record = ArtworkData(
      id: hash,
      relativePath: relativePath,
      contentHash: hash,
      mimeType: mime,
      width: image.width,
      height: image.height,
      fileSize: bytes.length,
      createdAt: DateTime.now(),
    );
    await db.into(db.artwork).insert(record);
    AppLogger.info('Stored artwork $relativePath (${bytes.length} bytes)', tag: 'artwork');
    return record;
  }

  /// Resolves a stored artwork record to an absolute path for display.
  /// Returns null when the artwork is missing (e.g. storage moved offline).
  Future<String?> absolutePathFor(String? artworkId) async {
    if (artworkId == null) return null;
    if (_pathCache.containsKey(artworkId)) return _pathCache[artworkId];
    final record = await (db.select(db.artwork)..where((a) => a.id.equals(artworkId))).getSingleOrNull();
    if (record == null) {
      _pathCache[artworkId] = null;
      return null;
    }
    final path = p.join(files.root, record.relativePath);
    final result = await File(path).exists() ? path : null;
    _pathCache[artworkId] = result;
    return result;
  }

  /// Drops resolved paths (e.g. after a storage move or restore).
  void clearPathCache() => _pathCache.clear();

  String _extForMime(String? mime) {
    switch (mime) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      default:
        return '.jpg';
    }
  }
}

class _ArtworkInvalid implements Exception {
  const _ArtworkInvalid();
  @override
  String toString() => 'Artwork bytes are not a valid image';
}
