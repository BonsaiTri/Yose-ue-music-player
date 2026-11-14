import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/download_repository.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';
import 'package:music_player/features/downloader/domain/youtube_resolver.dart';

/// Internal signals for cooperative stop.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// Best-effort display metadata for a downloaded YouTube file.
class YtMeta {
  const YtMeta({this.title, this.artist, this.artwork});
  final String? title;
  final String? artist;
  final List<int>? artwork;
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

/// Outcome of expanding a playlist into individual download tasks.
class PlaylistQueueSummary {
  const PlaylistQueueSummary({required this.queued, required this.ignored});

  /// Tracks enqueued as individual download tasks.
  final int queued;

  /// Entries that could not be queued (duplicates, malformed, …).
  final int ignored;
}

/// One parsed entry of an M3U/M3U8 playlist.
class _M3uEntry {
  const _M3uEntry(this.url, this.title, this.artist);
  final String url;
  final String title;
  final String artist;
}

/// Hard cap on entries queued from a single playlist.
const int _maxPlaylistEntries = 200;

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
    this.ytDlp,
  });

  final DownloadRepository downloads;
  final FileService files;
  final ImportService importer;
  final int concurrency;

  /// yt-dlp backend for YouTube sources (created by bootstrap; injected in
  /// tests). YouTube downloads throw a clear error when this is absent.
  final YtDlpBackend? ytDlp;

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
    ytDlp?.close();
  }

  /// Enqueues a new download (source of truth is the database).
  Future<DownloadTask> queue({
    required String url,
    required String title,
    String artist = 'Unknown Artist',
    String album = 'Unknown Album',
    String? trackId,
    int priority = 0,
  }) async {
    _validateUrl(url);
    return downloads.create(
      url: url,
      title: title,
      artist: artist,
      album: album,
      trackId: trackId,
      priority: priority,
    );
  }

  /// Rejects URLs carrying control characters or whitespace. Dart's
  /// [Uri] percent-encodes newlines instead of rejecting them, so a
  /// pasted multi-line blob can otherwise masquerade as a valid URL.
  static void _validateUrl(String url) {
    if (RegExp(r'[\u0000-\u0020\u007F-\u00A0]').hasMatch(url)) {
      throw const DownloadTaskException(
          'Invalid URL — paste a plain single-line http(s) link');
    }
  }

  /// Enqueues every track in an M3U/M3U8 playlist at [url] as individual
  /// download tasks. Relative URLs are resolved against the playlist URL;
  /// nested playlists are skipped. Returns the queue summary.
  Future<PlaylistQueueSummary> queuePlaylist(String url) async {
    _validateUrl(url);
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const DownloadTaskException('Playlist URL must be http or https');
    }
    final body = await _fetchPlaylist(uri);
    final entries = _parseM3u(body, base: uri);
    if (entries.isEmpty) {
      throw const DownloadTaskException('No playable tracks found in playlist');
    }
    var queued = 0;
    var ignored = 0;
    for (final entry in entries) {
      try {
        await downloads.create(url: entry.url, title: entry.title, artist: entry.artist);
        queued++;
      } catch (_) {
        ignored++;
      }
    }
    if (queued == 0) {
      throw const DownloadTaskException('Could not queue any tracks from playlist');
    }
    AppLogger.info('Queued $queued tracks from playlist $url', tag: 'download');
    return PlaylistQueueSummary(queued: queued, ignored: ignored);
  }

  /// Enqueues a YouTube video or playlist.
  ///
  /// * Single video: one task whose source is the watch URL; the audio is
  ///   downloaded via yt-dlp at execution time (stream URLs and PO tokens
  ///   expire, so nothing is pre-resolved).
  /// * Playlist: every track becomes a task with its watch URL; titles come
  ///   from a flat yt-dlp listing (no per-track network cost).
  Future<PlaylistQueueSummary> queueYouTube(String url) async {
    _validateUrl(url);
    if (!YouTubeResolver.isYouTubeUrl(url)) {
      throw const DownloadTaskException('Not a YouTube URL');
    }
    final backend = ytDlp;
    if (backend == null) {
      throw const DownloadTaskException(
          'YouTube downloading is not available on this platform');
    }
    try {
      final entries = await backend.list(url);
      if (entries.isEmpty) {
        throw const DownloadTaskException('No tracks found at this YouTube URL');
      }
      var queued = 0;
      var ignored = 0;
      for (final entry in entries.take(_maxPlaylistEntries)) {
        try {
          await downloads.create(
            url: entry.watchUrl,
            title: entry.title,
            artist: entry.channel ?? 'Unknown Artist',
          );
          queued++;
        } catch (_) {
          ignored++;
        }
      }
      if (queued == 0) {
        throw const DownloadTaskException('Could not queue any tracks from playlist');
      }
      AppLogger.info('Queued $queued tracks from YouTube $url', tag: 'download');
      return PlaylistQueueSummary(queued: queued, ignored: ignored);
    } on YtDlpException catch (e) {
      throw DownloadTaskException(e.message);
    }
  }

  /// Fetches a playlist body (bounded to 2 MB).
  Future<String> _fetchPlaylist(Uri uri) async {
    final client = _client ?? HttpClient()..connectionTimeout = _connectTimeout;
    _client = client;
    final req = await client.getUrl(uri).timeout(_requestTimeout);
    final res = await req.close().timeout(_requestTimeout);
    if (res.statusCode != 200) {
      await res.drain();
      throw DownloadTaskException('Playlist fetch failed: HTTP ${res.statusCode}');
    }
    final chunks = <List<int>>[];
    var total = 0;
    await for (final chunk in res) {
      total += chunk.length;
      if (total > 2 * 1024 * 1024) {
        await res.drain();
        throw const DownloadTaskException('Playlist too large (max 2 MB)');
      }
      chunks.add(chunk);
    }
    return String.fromCharCodes(chunks.expand((c) => c));
  }

  /// Parses M3U/M3U8 [body] into playable entries (max [_maxPlaylistEntries]).
  /// `#EXTINF:dur,Artist - Title` labels the following URL line; plain URL
  /// lines are titled from their file name.
  List<_M3uEntry> _parseM3u(String body, {required Uri base}) {
    final entries = <_M3uEntry>[];
    String? pendingTitle;
    String? pendingArtist;
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final m =
            RegExp(r'^#EXTINF:\s*[-\d.]*\s*,\s*(.*)$').firstMatch(line);
        if (m == null) continue; // #EXTM3U, #EXT, …
        final label = m.group(1)!.trim();
        // Common "Artist - Title" convention.
        final dash = label.indexOf(' - ');
        if (dash > 0) {
          pendingArtist = label.substring(0, dash).trim();
          pendingTitle = label.substring(dash + 3).trim();
        } else {
          pendingArtist = null;
          pendingTitle = label;
        }
        continue;
      }
      final resolved = Uri.tryParse(line);
      if (resolved == null || resolved.path.isEmpty) continue;
      final abs = resolved.hasScheme ? resolved : base.resolve(line);
      final path = abs.path.toLowerCase();
      // Nested playlists are not downloadable as files.
      if (path.endsWith('.m3u') || path.endsWith('.m3u8')) {
        pendingTitle = null;
        pendingArtist = null;
        continue;
      }
      final title =
          (pendingTitle != null && pendingTitle.isNotEmpty) ? pendingTitle : _titleFromUrl(abs);
      entries.add(_M3uEntry(abs.toString(), title, pendingArtist ?? 'Unknown Artist'));
      pendingTitle = null;
      pendingArtist = null;
      if (entries.length >= _maxPlaylistEntries) break;
    }
    return entries;
  }

  String _titleFromUrl(Uri uri) {
    final name = p.basenameWithoutExtension(uri.path);
    try {
      return Uri.decodeComponent(name);
    } catch (_) {
      return name;
    }
  }

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
    YtMeta? ytMeta;
    try {
      // Re-check state: the task may have been cancelled/retried between
      // polling and execution, or another run may own it.
      final task = await downloads.byId(id);
      if (task == null || task.status != DownloadTaskStatus.queued) return;
      if (!_isWebUrl(task.url)) {
        throw DownloadTaskException('URL must be http or https');
      }

      final isYouTube = YouTubeResolver.isYouTubeUrl(task.url);
      String? forcedExtension;
      late File target;

      if (isYouTube) {
        // YouTube: yt-dlp handles stream resolution, PO tokens and rate
        // limiting internally. The watch URL stays the persisted source,
        // so retries always start fresh.
        final backend = ytDlp;
        if (backend == null) {
          throw const DownloadTaskException(
              'YouTube downloading is not available on this platform');
        }
        if (_cancelled.contains(id)) throw const _Cancelled();
        tempPath = p.join(files.tempDir, 'ytdl_$id');
        await downloads.updateStatus(id, DownloadTaskStatus.preparing, tempPath: tempPath);
        if (_cancelled.contains(id)) throw const _Cancelled();
        await downloads.updateStatus(id, DownloadTaskStatus.downloading);
        String downloadedPath;
        try {
          downloadedPath = await backend.downloadAudio(
            url: task.url,
            workDir: tempPath,
            processKey: id,
            expectedId: YouTubeResolver.videoIdFromUrl(task.url) ?? 'unknown',
            shouldCancel: () => _cancelled.contains(id),
            onProgress: (progress) => _flushYtProgress(id, progress),
          );
        } on YtDlpException catch (e) {
          if (_cancelled.contains(id)) throw const _Cancelled();
          throw DownloadTaskException(e.message);
        }
        // Use the real stream format (m4a preferred, webm possible).
        final ext =
            p.extension(downloadedPath).toLowerCase().replaceAll('.', '');
        if (ext.isNotEmpty && AppConstants.audioExtensions.contains(ext)) {
          forcedExtension = ext;
        }
        // PROCESSING: atomic move into the downloads dir.
        await downloads.updateStatus(id, DownloadTaskStatus.processing, progress: 1.0);
        target = _finalPath(task, extensionOverride: forcedExtension);
        await files.atomicMove(downloadedPath, target.path);
        tempPath = null; // owned by the library from here on
        // Enrich: yt-dlp audio files carry no embedded metadata or cover.
        // One flat listing gives us the title, channel and thumbnail URL.
        ytMeta = await _fetchYtMeta(backend, task.url);
      } else {
        // PREPARING: allocate the temp file, probe expected size.
        String effectiveUrl = task.url;
        tempPath = p.join(files.tempDir, 'dl_${id}.part');
        await downloads.updateStatus(id, DownloadTaskStatus.preparing, tempPath: tempPath);
        if (_cancelled.contains(id)) throw const _Cancelled();
        final expected = await _probeLength(effectiveUrl);
        if (expected != null) {
          await downloads.updateStatus(id, DownloadTaskStatus.preparing, bytesExpected: expected);
        }

        // DOWNLOADING: stream to the temp file with throttled progress.
        if (_cancelled.contains(id)) throw const _Cancelled();
        await downloads.updateStatus(id, DownloadTaskStatus.downloading);
        final done = await _downloadToFile(id, effectiveUrl, tempPath, expected);

        // PROCESSING: atomic move into the downloads dir, register in library.
        await downloads.updateStatus(id, DownloadTaskStatus.processing,
            progress: 1.0, bytesDone: done, speedBps: 0);
        target = _finalPath(task);
        await files.atomicMove(tempPath, target.path);
        tempPath = null; // owned by the library from here on
      }

      // Reject pages/garque that merely *look* like files (wrong content).
      if (!await _looksLikeAudioFile(target.path)) {
        throw const DownloadTaskException(
            'Downloaded file is not a recognized audio format');
      }

      final track = await importer.registerDownloadedFile(
        target.path,
        sourceType: 'download',
        titleOverride: ytMeta?.title,
        artistOverride: ytMeta?.artist,
        artworkBytes: ytMeta?.artwork,
        artworkMime: 'image/jpeg',
      );
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
      _ytProgressClock.remove(id);
    }
  }

  /// Title/artist/cover for a YouTube source, fetched best-effort so a
  /// metadata hiccup never fails an otherwise-complete download.
  Future<YtMeta> _fetchYtMeta(YtDlpBackend backend, String url) async {
    try {
      final entries = await backend.list(url);
      if (entries.isEmpty) return const YtMeta();
      final first = entries.first;
      final thumbUrl = (first.thumbnail != null && first.thumbnail!.isNotEmpty)
          ? first.thumbnail!
          : 'https://i.ytimg.com/vi/${first.id}/hqdefault.jpg';
      final artwork = await _fetchImage(thumbUrl);
      return YtMeta(
          title: first.title,
          artist: first.channel,
          artwork: artwork);
    } catch (e) {
      AppLogger.warning('YouTube metadata fetch failed: $e', tag: 'download');
      return const YtMeta();
    }
  }

  /// GETs [url] into memory (8 MB cap). Returns null on any failure; the
  /// caller validates the image bytes when storing.
  Future<List<int>?> _fetchImage(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > 8 * 1024 * 1024) return null;
      }
      final bytes = builder.toBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _fail(String id, Object e, String? tempPath) async {
    // tempPath is either a .part file (direct downloads) or a work
    // directory (yt-dlp downloads).
    if (tempPath != null) {
      try {
        final f = File(tempPath);
        if (f.existsSync()) await f.delete(); else {
          final d = Directory(tempPath);
          if (d.existsSync()) await d.delete(recursive: true);
        }
      } catch (_) {}
    }
    if (e is _Cancelled) {
      await downloads.updateStatus(id, DownloadTaskStatus.cancelled);
    } else if (e is _Paused) {
      await downloads.updateStatus(id, DownloadTaskStatus.paused);
    } else {
      final message = e is DownloadTaskException
          ? e.message
          : e is YtDlpException
              ? e.message
              : '$e';
      AppLogger.error('Download $id failed: $message', tag: 'download');
      await downloads.updateStatus(id, DownloadTaskStatus.failed, error: message);
    }
  }

  /// Throttled progress persistence for yt-dlp runs (fraction only; the
  /// backend reports percent + ETA, not byte counts).
  final _ytProgressClock = <String, DateTime>{};

  Future<void> _flushYtProgress(String id, YtDlpProgress progress) async {
    final now = DateTime.now();
    final last = _ytProgressClock[id];
    if (last != null && now.difference(last) < _progressFlush) return;
    _ytProgressClock[id] = now;
    try {
      await downloads.updateStatus(
          id, DownloadTaskStatus.downloading, progress: progress.fraction);
    } catch (_) {
      // Progress persistence is best-effort.
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

  /// Cheap content sniff: does the file start with an audio magic number
  /// (ID3/MPEG frame, ftyp, fLaC, OggS, RIFF/WAVE)?
  Future<bool> _looksLikeAudioFile(String path) async {
    final f = File(path);
    if (!f.existsSync() || await f.length() < 12) return false;
    final raf = await f.open(mode: FileMode.read);
    try {
      final head = raf.readSync(12);
      bool matches(int offset, List<int> sig) {
        if (head.length < offset + sig.length) return false;
        for (var i = 0; i < sig.length; i++) {
          if (head[offset + i] != sig[i]) return false;
        }
        return true;
      }
      // MP3: ID3 tag or a bare MPEG frame sync.
      if (matches(0, [0x49, 0x44, 0x33]) ||
          (head.length >= 2 &&
              head[0] == 0xFF &&
              (head[1] & 0xE0) == 0xE0)) {
        return true;
      }
      // MP4/M4A: 'ftyp' at offset 4.
      if (matches(4, [0x66, 0x74, 0x79, 0x70])) return true;
      // FLAC: 'fLaC'. OGG: 'OggS'. WAV: 'RIFF....WAVE'.
      if (matches(0, [0x66, 0x4C, 0x61, 0x43])) return true;
      if (matches(0, [0x4F, 0x67, 0x67, 0x53])) return true;
      if (matches(0, [0x52, 0x49, 0x46, 0x46]) && matches(8, [0x57, 0x41, 0x56, 0x45])) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      raf.closeSync();
    }
  }

  /// Destination file for a finished download (collision-safe).
  File _finalPath(DownloadTask task, {String? extensionOverride}) {
    final base = _safeName(task.title);
    final ext = extensionOverride != null &&
            AppConstants.audioExtensions.contains(extensionOverride) &&
            extensionOverride.isNotEmpty
        ? '.$extensionOverride'
        : _extensionFor(task.url);
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
    // YouTube watch URLs have no extension; callers pass an override.
    if (YouTubeResolver.isYouTubeUrl(url)) return '.m4a';
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
