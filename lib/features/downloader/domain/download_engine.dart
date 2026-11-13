import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/download_repository.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';

/// Internal signals for cooperative stop.
class _Cancelled implements Exception {
  const _Cancelled();
}

class _Paused implements Exception {
  const _Paused();
}

class DownloadTaskException implements Exception {
  const DownloadTaskException(this.message);
  final String message;

  @override
  String toString() => 'DownloadTaskException: $message';
}

/// Milestone 4: background download queue executor.
///
/// Per-task lifecycle (persisted to `download_tasks`):
///
/// ```
/// queued -> preparing -> downloading -> processing -> validating -> completed
///    \--------\----------------/          any stage -> failed (retryable)
///    \--------\----------------/          queued/active -> cancelled | paused
/// ```
///
/// The engine polls the queue on a timer, runs up to [concurrency] tasks in
/// parallel, persists progress to the database (throttled), and supports
/// cancel/pause/retry. Downloads are written to a temp file and atomically
/// moved into the downloads directory, then registered into the library via
/// the shared import pipeline.
class DownloadEngine {
  DownloadEngine({
    required this.downloads,
    required this.files,
    required this.importer,
    this.concurrency = AppConstants.maxConcurrentDownloads,
  });

  final DownloadRepository downloads;
  final FileService files;
  final ImportService importer;
  final int concurrency;

  static const _pollInterval = Duration(seconds: 2);
  static const _progressFlush = Duration(milliseconds: 500);
  static const _connectTimeout = Duration(seconds: 30);
  static const _requestTimeout = Duration(seconds: 60);

  final _running = <String>{};
  final _cancelled = <String>{};
  final _paused = <String>{};
  Timer? _poll;
  bool _started = false;
  HttpClient? _client;

  int get activeCount => _running.length;
  bool get started => _started;

  /// Stream of tasks currently in an active stage (for live UI updates).
  Stream<List<DownloadTask>> get active => downloads.watchActive();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _poll = Timer.periodic(_pollInterval, (_) => _tick());
    await _tickAsync();
  }

  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    _started = false;
    _client?.close(force: true);
    _client = null;
  }

  /// Enqueues a new download (source of truth is the database).
  Future<DownloadTask> queue({
    required String url,
    required String title,
    String artist = 'Unknown Artist',
    String album = 'Unknown Album',
    String? trackId,
    int priority = 0,
  }) =>
      downloads.create(
        url: url,
        title: title,
        artist: artist,
        album: album,
        trackId: trackId,
        priority: priority,
      );

  /// Cancels a queued or in-flight task.
  Future<bool> cancel(String id) async {
    if (_running.contains(id)) {
      _cancelled.add(id);
      return true;
    }
    return downloads.cancel(id);
  }

  /// Pauses a queued or in-flight task. The partial temp file is discarded;
  /// retrying starts the download over.
  Future<bool> pause(String id) async {
    if (_running.contains(id)) {
      _paused.add(id);
      return true;
    }
    final task = await downloads.byId(id);
    if (task == null) return false;
    if (task.status == DownloadTaskStatus.queued ||
        task.status == DownloadTaskStatus.preparing ||
        task.status == DownloadTaskStatus.downloading) {
      await downloads.updateStatus(id, DownloadTaskStatus.paused);
      return true;
    }
    return false;
  }

  /// Re-queues a failed, cancelled or paused task.
  Future<void> retry(String id) => downloads.retry(id);

  void _tick() {
    _tickAsync().catchError((Object e, StackTrace st) {
      AppLogger.error('Download poll failed: $e', tag: 'download');
    });
  }

  Future<void> _tickAsync() async {
    final slots = concurrency - _running.length;
    if (slots <= 0) return;
    final batch = await downloads.queued(limit: slots);
    for (final task in batch) {
      if (_running.contains(task.id) || _cancelled.contains(task.id)) continue;
      _running.add(task.id);
      _runTask(task.id).catchError((Object e, StackTrace st) {
        AppLogger.error('Download ${task.id} crashed: $e', tag: 'download');
      });
    }
  }

  Future<void> _runTask(String id) async {
    String? tempPath;
    try {
      // Re-check state: the task may have been cancelled/retried between
      // polling and execution, or another run may own it.
      final task = await downloads.byId(id);
      if (task == null || task.status != DownloadTaskStatus.queued) return;
      if (!_isWebUrl(task.url)) {
        throw DownloadTaskException('URL must be http or https');
      }

      // PREPARING: allocate the temp file, probe expected size.
      tempPath = p.join(files.tempDir, 'dl_${id}.part');
      await downloads.updateStatus(id, DownloadTaskStatus.preparing, tempPath: tempPath);
      if (_cancelled.contains(id)) throw const _Cancelled();
      final expected = await _probeLength(task.url);
      if (expected != null) {
        await downloads.updateStatus(id, DownloadTaskStatus.preparing, bytesExpected: expected);
      }

      // DOWNLOADING: stream to the temp file with throttled progress.
      if (_cancelled.contains(id)) throw const _Cancelled();
      await downloads.updateStatus(id, DownloadTaskStatus.downloading);
      final done = await _downloadToFile(id, task.url, tempPath, expected);

      // PROCESSING: atomic move into the downloads dir, register in library.
      await downloads.updateStatus(id, DownloadTaskStatus.processing,
          progress: 1.0, bytesDone: done, speedBps: 0);
      final target = _finalPath(task);
      await files.atomicMove(tempPath, target.path);
      tempPath = null; // owned by the library from here on

      final track =
          await importer.registerDownloadedFile(target.path, sourceType: 'download');
      if (track == null) {
        throw DownloadTaskException('Downloaded file is not a recognized audio format');
      }

      // VALIDATING: existence, size integrity.
      if (_cancelled.contains(id)) throw const _Cancelled();
      await downloads.updateStatus(id, DownloadTaskStatus.validating);
      final length = await target.length();
      if (length == 0) {
        throw DownloadTaskException('Validation failed: file is empty');
      }
      final fresh = await downloads.byId(id);
      final expectedBytes = fresh?.bytesExpected;
      if (expectedBytes != null && length != expectedBytes) {
        throw DownloadTaskException(
            'Validation failed: size mismatch ($length != $expectedBytes)');
      }

      // COMPLETED.
      await downloads.updateStatus(id, DownloadTaskStatus.completed,
          progress: 1.0,
          bytesDone: length,
          finalPath: target.path,
          trackId: track.id,
          clearError: true);
      AppLogger.info('Download ${id} completed: ${track.title} -> ${target.path}',
          tag: 'download');
    } catch (e) {
      await _fail(id, e, tempPath);
    } finally {
      _running.remove(id);
      _cancelled.remove(id);
      _paused.remove(id);
    }
  }

  Future<void> _fail(String id, Object e, String? tempPath) async {
    if (tempPath != null) {
      try {
        final f = File(tempPath);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
    if (e is _Cancelled) {
      await downloads.updateStatus(id, DownloadTaskStatus.cancelled);
    } else if (e is _Paused) {
      await downloads.updateStatus(id, DownloadTaskStatus.paused);
    } else {
      final message = e is DownloadTaskException ? e.message : '$e';
      AppLogger.error('Download $id failed: $message', tag: 'download');
      await downloads.updateStatus(id, DownloadTaskStatus.failed, error: message);
    }
  }

  /// Streams [url] into [dest]. Returns total bytes written.
  /// Throws [DownloadTaskException] on non-2xx or transport errors, and
  /// [_Cancelled]/[_Paused] when the caller signals a stop.
  Future<int> _downloadToFile(String id, String url, String dest, int? expected) async {
    final client = _client ?? HttpClient()..connectionTimeout = _connectTimeout;
    _client = client;
    var written = 0;
    var out = await File(dest).open(mode: FileMode.write);
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_requestTimeout);
      final res = await req.close().timeout(_requestTimeout);
      if (res.statusCode != 200) {
        await res.drain();
        throw DownloadTaskException('HTTP ${res.statusCode}');
      }

      var windowBytes = 0;
      var windowStart = DateTime.now();
      var lastFlush = windowStart;
      await for (final chunk in res) {
        if (_cancelled.contains(id)) throw const _Cancelled();
        if (_paused.contains(id)) throw const _Paused();
        await out.writeFrom(chunk); // HttpClientResponse events are Uint8List
        written += chunk.length;
        windowBytes += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastFlush) >= _progressFlush) {
          final ms = now.difference(windowStart).inMilliseconds;
          final speed = ms > 0 ? (windowBytes * 1000) ~/ ms : 0;
          final total = res.contentLength > 0 ? res.contentLength : (expected ?? 0);
          final progress = total > 0 ? (written / total).clamp(0.0, 1.0) : 0.0;
          await downloads.updateStatus(id, DownloadTaskStatus.downloading,
              progress: progress, bytesDone: written, speedBps: speed);
          windowBytes = 0;
          windowStart = now;
          lastFlush = now;
        }
      }
      // Final flush so the persisted state is exact when the stream ends.
      final total = res.contentLength > 0 ? res.contentLength : (expected ?? 0);
      final progress = total > 0 ? (written / total).clamp(0.0, 1.0) : 1.0;
      await downloads.updateStatus(id, DownloadTaskStatus.downloading,
          progress: progress, bytesDone: written, speedBps: 0);
    } catch (e) {
      if (e is _Cancelled || e is _Paused) rethrow;
      if (e is DownloadTaskException) rethrow;
      if (e is TimeoutException) {
        throw const DownloadTaskException('Request timed out');
      }

      throw DownloadTaskException('Network error: $e');
    } finally {
      await out.close();
    }
    return written;
  }

  /// Best-effort expected size via a HEAD request (null if unavailable).
  Future<int?> _probeLength(String url) async {
    try {
      final client = _client ?? HttpClient()..connectionTimeout = _connectTimeout;
      _client = client;
      final req = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 15));
      await res.drain();
      final len = res.contentLength;
      return len > 0 ? len : null;
    } catch (_) {
      return null;
    }
  }

  /// Destination file for a finished download (collision-safe).
  File _finalPath(DownloadTask task) {
    final base = _safeName(task.title);
    final ext = _extensionFor(task.url);
    var candidate = p.join(files.downloadsDir, '$base$ext');
    var n = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(files.downloadsDir, '$base ($n)$ext');
      n++;
    }
    return File(candidate);
  }

  String _safeName(String title) {
    var name = title.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    if (name.length > 80) name = name.substring(0, 80);
    return name.isEmpty ? 'download' : name;
  }

  String _extensionFor(String url) {
    final ext = p.extension(Uri.parse(url).path).toLowerCase();
    if (ext.isEmpty || !AppConstants.audioExtensions.contains(ext.substring(1))) {
      return '.mp3';
    }
    return ext;
  }

  bool _isWebUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
