import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/download_repository.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';
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

/// Keeps the OS from killing the process while downloads run in the
/// background. Android implements this with a foreground service (a
/// backgrounded app's worker child processes are prime low-memory-killer
/// targets); desktop platforms no-op.
abstract class DownloadProcessGuard {
  Future<void> start();

  Future<void> stop();
}

class DownloadTaskException implements Exception {
  const DownloadTaskException(this.message);
  final String message;

  @override
  String toString() => 'DownloadTaskException: $message';
}

/// The exact source was already downloaded and its file (or library track)
/// is still present, so re-downloading would just overwrite a good copy.
class AlreadyDownloadedError extends DownloadTaskException {
  const AlreadyDownloadedError([String? title])
      : super(title == null
            ? 'Already downloaded — it is in your library'
            : '“$title” is already downloaded — it is in your library');
}

/// The exact source already has a task that is queued, active, or paused.
class AlreadyInQueueError extends DownloadTaskException {
  const AlreadyInQueueError([String? title])
      : super(title == null
            ? 'Already in the download queue'
            : '“$title” is already in the download queue');
}

/// Outcome of expanding a playlist into individual download tasks.
class PlaylistQueueSummary {
  const PlaylistQueueSummary(
      {required this.queued,
      required this.ignored,
      this.alreadyDownloaded = 0});

  /// Tracks enqueued as individual download tasks.
  final int queued;

  /// Entries that could not be queued (duplicates, malformed, …).
  final int ignored;

  /// Entries skipped because they are already downloaded (file/track still
  /// present in the library).
  final int alreadyDownloaded;
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
    this.playlists,
    this.guard,
  });

  final DownloadRepository downloads;
  final FileService files;
  final ImportService importer;
  final int concurrency;

  /// yt-dlp backend for YouTube sources (created by bootstrap; injected in
  /// tests). YouTube downloads throw a clear error when this is absent.
  final YtDlpBackend? ytDlp;

  /// When present, playlist downloads (M3U/M3U8 or YouTube playlists) are
  /// grouped into an app playlist named after the source, and finished
  /// tracks are added to it automatically.
  final PlaylistRepository? playlists;

  /// Background-process protection (Android foreground service). Started
  /// while tasks are running, stopped when the queue drains.
  final DownloadProcessGuard? guard;
  bool _guardActive = false;

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
    await _recoverOrphaned();
    _poll = Timer.periodic(_pollInterval, (_) => _tick());
    await _tickAsync();
  }

  /// Re-queue tasks that were mid-flight when the app was killed or
  /// crashed, and delete the temp files those dead runs left behind.
  /// Without this, tasks stuck in preparing/downloading/processing/
  /// validating would never run again and their temp data would leak.
  Future<void> _recoverOrphaned() async {
    try {
      var recovered = 0;
      for (final status in <DownloadTaskStatus>[
        DownloadTaskStatus.preparing,
        DownloadTaskStatus.downloading,
        DownloadTaskStatus.processing,
        DownloadTaskStatus.validating,
      ]) {
        for (final task in await downloads.byStatus(status)) {
          await downloads.updateStatus(task.id, DownloadTaskStatus.queued);
          recovered++;
        }
      }
      final tmp = Directory(files.tempDir);
      if (await tmp.exists()) {
        for (final entity in tmp.listSync()) {
          try {
            if (entity is File) {
              await entity.delete();
            } else if (entity is Directory) {
              await entity.delete(recursive: true);
            }
          } catch (_) {
            // Best-effort cleanup; never block startup on a stale temp file.
          }
        }
      }
      if (recovered > 0) {
        AppLogger.info('Recovered $recovered interrupted download(s)',
            tag: 'download');
      }
    } catch (e) {
      AppLogger.warning('Download recovery failed: $e', tag: 'download');
    }
  }

  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    _started = false;
    _client?.close(force: true);
    _client = null;
    if (_guardActive) {
      _guardActive = false;
      try {
        await guard?.stop();
      } catch (_) {
        // Best-effort; the service stops itself with the process.
      }
    }
    ytDlp?.close();
  }

  /// Starts the background guard once real work is running.
  Future<void> _ensureGuardActive() async {
    if (_guardActive || _running.isEmpty) return;
    _guardActive = true;
    try {
      await guard?.start();
    } catch (e) {
      AppLogger.warning('Download guard start failed: $e', tag: 'download');
    }
  }

  /// Stops the background guard once nothing is running and nothing is
  /// queued, so the notification goes away when work is done.
  Future<void> _maybeStopGuard() async {
    if (!_guardActive || _running.isNotEmpty) return;
    try {
      final remaining = await downloads.queued(limit: 1);
      if (remaining.isNotEmpty) return;
    } catch (_) {
      return;
    }
    _guardActive = false;
    try {
      await guard?.stop();
    } catch (e) {
      AppLogger.warning('Download guard stop failed: $e', tag: 'download');
    }
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
    await _ensureNotDuplicate(url, title: title, artist: artist);
    return downloads.create(
      url: url,
      title: title,
      artist: artist,
      album: album,
      trackId: trackId,
      priority: priority,
    );
  }

  /// Refuses to enqueue [url] when the music is already present:
  ///
  /// * [AlreadyInQueueError] — a queued/active/paused task uses the same
  ///   source,
  /// * [AlreadyDownloadedError] — a completed task used it and the file or
  ///   library track is still present (a completed task whose file was
  ///   deleted is *not* a duplicate — re-downloading is correct), or a track
  ///   with the same title and artist is already in the library (a
  ///   different upload of a song the user already owns).
  ///
  /// YouTube URLs are compared in canonical form so format variants
  /// (`youtu.be`, extra query parameters) still match.
  Future<void> _ensureNotDuplicate(
    String url, {
    String? title,
    String? artist,
  }) async {
    final canonical = YouTubeResolver.canonicalUrl(url);
    final tasks = await downloads.byStatuses(const [
      DownloadTaskStatus.queued,
      DownloadTaskStatus.preparing,
      DownloadTaskStatus.downloading,
      DownloadTaskStatus.processing,
      DownloadTaskStatus.validating,
      DownloadTaskStatus.paused,
      DownloadTaskStatus.completed,
    ]);
    for (final task in tasks) {
      if (YouTubeResolver.canonicalUrl(task.url) != canonical) continue;
      if (task.status == DownloadTaskStatus.completed) {
        if (await _stillInLibrary(task)) {
          throw AlreadyDownloadedError(title ?? task.title);
        }
      } else {
        throw AlreadyInQueueError(title ?? task.title);
      }
    }
    if (title != null && await _inLibrary(title, artist)) {
      throw AlreadyDownloadedError(title);
    }
  }

  /// True when the library already holds a track matching [title] — and
  /// [artist] when both are known. Titles are compared in normalized form
  /// (lowercase, punctuation-free, trailing parentheticals like
  /// "(official music video)" stripped) so different uploads of the same
  /// song match.
  Future<bool> _inLibrary(String title, String? artist) async {
    final wantTitle = _songKey(title);
    if (wantTitle.isEmpty) return false;
    final wantArtist = _songKey(artist ?? '');
    for (final track in await importer.tracks.allTracks()) {
      if (_songKey(track.title) != wantTitle) continue;
      final trackArtist = _songKey(track.artist);
      if (wantArtist.isEmpty ||
          trackArtist.isEmpty ||
          trackArtist == wantArtist) {
        return true;
      }
    }
    return false;
  }

  /// Normalized comparison key for song titles/artists.
  static String _songKey(String raw) {
    var s = raw.trim().toLowerCase();
    // Strip a short trailing parenthetical/bracket suffix, e.g.
    // "(official music video)", "(live)".
    final close = s.lastIndexOf(RegExp(r'[)\]]'));
    if (close >= 1 && close == s.length - 1) {
      final openParen = s.lastIndexOf('(', close);
      final openBracket = s.lastIndexOf('[', close);
      final openAt = openParen > openBracket ? openParen : openBracket;
      if (openAt > 0 && close - openAt <= 40) s = s.substring(0, openAt);
    }
    s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// True when a completed task's music is still reachable: its library
  /// track exists, or the final file is still on disk.
  Future<bool> _stillInLibrary(DownloadTask task) async {
    final trackId = task.trackId;
    if (trackId != null && await importer.tracks.byId(trackId) != null) {
      return true;
    }
    final path = task.finalPath;
    return path != null && File(path).existsSync();
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
  /// nested playlists are skipped. The tracks are grouped into an app
  /// playlist named after the source (`#PLAYLIST:` directive, else the
  /// file name) and joined to it as they finish. Returns the queue summary.
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
    final playlistId =
        await _resolveOrCreatePlaylist(_m3uPlaylistName(body, uri));
    var queued = 0;
    var ignored = 0;
    var already = 0;
    for (final entry in entries) {
      try {
        await _ensureNotDuplicate(entry.url, title: entry.title, artist: entry.artist);
      } on AlreadyDownloadedError {
        already++;
        continue;
      } on AlreadyInQueueError {
        ignored++;
        continue;
      }
      try {
        await downloads.create(
            url: entry.url,
            title: entry.title,
            artist: entry.artist,
            playlistId: playlistId);
        queued++;
      } catch (_) {
        ignored++;
      }
    }
    if (queued == 0) {
      throw already > 0
          ? const AlreadyDownloadedError()
          : const DownloadTaskException('Could not queue any tracks from playlist');
    }
    AppLogger.info('Queued $queued tracks from playlist $url', tag: 'download');
    return PlaylistQueueSummary(
        queued: queued, ignored: ignored, alreadyDownloaded: already);
  }

  /// Enqueues a YouTube video or playlist.
  ///
  /// * Single video: one task whose source is the watch URL; the audio is
  ///   downloaded via yt-dlp at execution time (stream URLs and PO tokens
  ///   expire, so nothing is pre-resolved).
  /// * Playlist: every track becomes a task with its watch URL; titles come
  ///   from a flat yt-dlp listing (no per-track network cost). The tracks
  ///   are grouped into an app playlist named after the source playlist and
  ///   joined to it as they finish.
  Future<PlaylistQueueSummary> queueYouTube(
    String url, {
    String? playlistName,
  }) async {
    _validateUrl(url);
    if (!YouTubeResolver.isYouTubeUrl(url)) {
      throw const DownloadTaskException('Not a YouTube URL');
    }
    final backend = ytDlp;
    if (backend == null) {
      throw const DownloadTaskException(
          'YouTube downloading is not available on this platform');
    }
    final playlistId = await _playlistIdForYouTube(url, playlistName);
    try {
      final entries = await backend.list(url);
      if (entries.isEmpty) {
        throw const DownloadTaskException('No tracks found at this YouTube URL');
      }
      var queued = 0;
      var ignored = 0;
      var already = 0;
      for (final entry in entries.take(_maxPlaylistEntries)) {
        try {
          await _ensureNotDuplicate(entry.watchUrl,
              title: entry.title,
              artist: entry.channel);
        } on AlreadyDownloadedError {
          already++;
          continue;
        } on AlreadyInQueueError {
          ignored++;
          continue;
        }
        try {
          await downloads.create(
            url: entry.watchUrl,
            title: entry.title,
            artist: entry.channel ?? 'Unknown Artist',
            playlistId: playlistId,
          );
          queued++;
        } catch (_) {
          ignored++;
        }
      }
      if (queued == 0) {
        throw already > 0
            ? (entries.length == 1
                ? AlreadyDownloadedError(entries.first.title)
                : const AlreadyDownloadedError())
            : const DownloadTaskException('Could not queue any tracks from playlist');
      }
      AppLogger.info('Queued $queued tracks from YouTube $url', tag: 'download');
      return PlaylistQueueSummary(
          queued: queued, ignored: ignored, alreadyDownloaded: already);
    } on YtDlpException catch (e) {
      throw DownloadTaskException(e.message);
    }
  }

  /// Resolves (or creates) the app playlist a named playlist download
  /// should land in, returning its id. A playlist with the same name is
  /// reused so re-downloading the same source accumulates in one playlist.
  Future<String?> _resolveOrCreatePlaylist(String name) async {
    final repo = playlists;
    if (repo == null) return null;
    final n = name.trim();
    if (n.isEmpty) return null;
    final existing = await repo.byName(n);
    final playlist = existing ?? await repo.create(n);
    AppLogger.info(
        'Playlist download → “${playlist.name}” (${existing == null ? 'created' : 'reused'})',
        tag: 'download');
    return playlist.id;
  }

  /// Playlist id for a YouTube [url]: null for single videos, otherwise the
  /// playlist named after the source. The name comes from [playlistName]
  /// when given, else from a cheap yt-dlp metadata fetch.
  Future<String?> _playlistIdForYouTube(String url, String? requestedName) async {
    if (!_isYouTubePlaylistUrl(url) || playlists == null || ytDlp == null) {
      return null;
    }
    String name = requestedName?.trim() ?? '';
    if (name.isEmpty) {
      name = (await ytDlp!.playlistTitle(url))?.trim() ?? '';
    }
    if (name.isEmpty) name = 'YouTube playlist';
    return _resolveOrCreatePlaylist(name);
  }

  /// True for YouTube playlist/mix URLs (list/mix query param or path).
  static bool _isYouTubePlaylistUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.queryParameters.containsKey('list')) return true;
    final path = uri.path;
    return path.contains('/playlist') || path.contains('/mix');
  }

  /// Display name of an M3U playlist: the `#PLAYLIST:` directive when
  /// present, otherwise the file name (percent-decoded).
  String _m3uPlaylistName(String body, Uri uri) {
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^#PLAYLIST:\s*(.+)$', caseSensitive: false)
          .firstMatch(raw.trim());
      if (m != null) {
        final name = (m.group(1) ?? '').trim();
        if (name.isNotEmpty) return name;
      }
    }
    final name = _titleFromUrl(uri);
    return name.isEmpty ? 'Imported playlist' : name;
  }

  /// Searches YouTube and returns up to [maxResults] matches (title,
  /// channel, thumbnail). Uses yt-dlp's built-in `ytsearchN:query` search
  /// extractor, so no separate search API is needed. Tap a result in the
  /// UI to queue it via [queueYouTube].
  Future<List<YtDlpEntry>> searchYouTube(
    String query, {
    int maxResults = 8,
  }) async {
    final backend = ytDlp;
    if (backend == null) {
      throw const DownloadTaskException(
          'YouTube downloading is not available on this platform');
    }
    final q = query.trim();
    if (q.isEmpty) throw const DownloadTaskException('Enter a search query');
    if (q.length > 200) throw const DownloadTaskException('Search query too long');
    final cap = maxResults.clamp(1, 20);
    final url = 'ytsearch$cap:$q';
    try {
      final entries = await backend.list(url);
      return entries.take(cap).toList();
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

  /// Re-queues every failed task in one action. Returns how many were
  /// retried (0 when there is nothing to retry). The periodic poll picks
  /// them up on its own.
  Future<int> retryFailed() async {
    final failed = await downloads.failed();
    for (final task in failed) {
      await downloads.retry(task.id);
    }
    return failed.length;
  }

  void _tick() {
    _tickAsync().catchError((Object e, StackTrace st) {
      AppLogger.error('Download poll failed: $e', tag: 'download');
    });
  }

  Future<void> _tickAsync() async {
    await _ensureGuardActive();
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
        // Title/artist are already known from queue time (the flat
        // listing populated the task); the cover is fetched straight from
        // i.ytimg.com. No second yt-dlp run per track — that was slow and
        // got rate-limited on long playlists.
        ytMeta = await _ytEnrichment(backend, task);
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

      // Playlist downloads: join the finished track to its playlist.
      // Best-effort — a hiccup here never fails an otherwise-complete file.
      final owningPlaylistId = task.playlistId;
      if (owningPlaylistId != null && playlists != null) {
        try {
          await playlists!.addTracks(owningPlaylistId, [track.id]);
        } catch (e) {
          AppLogger.warning('Could not add track to playlist: $e', tag: 'download');
        }
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
      await _maybeStopGuard();
    }
  }

  /// Title/artist/cover for a completed YouTube task.
  ///
  /// Title and artist come from the task itself (populated by the flat
  /// listing at queue time). The cover is fetched directly from
  /// i.ytimg.com using the video id — no extra yt-dlp process. Only when
  /// something is missing do we fall back to a full flat listing.
  Future<YtMeta> _ytEnrichment(
      YtDlpBackend backend, DownloadTask task) async {
    String? title =
        task.title.trim().isEmpty ? null : task.title.trim();
    String? artist = (task.artist.trim().isEmpty ||
            task.artist.trim() == 'Unknown Artist')
        ? null
        : task.artist.trim();
    List<int>? artwork;
    final videoId = YouTubeResolver.videoIdFromUrl(task.url);
    if (videoId != null) {
      artwork = await _fetchImage(
          'https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
    }
    if (title == null || artist == null || artwork == null) {
      final meta = await _fetchYtMeta(backend, task.url);
      title = title ?? meta.title;
      artist = artist ?? meta.artist;
      artwork = artwork ?? meta.artwork;
    }
    return YtMeta(title: title, artist: artist, artwork: artwork);
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
