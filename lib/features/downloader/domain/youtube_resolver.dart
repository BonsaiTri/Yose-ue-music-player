import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:music_player/core/logging/app_logger.dart';

/// Parsed reference to a YouTube video (no audio URL yet).
class YouTubeVideoRef {
  const YouTubeVideoRef({
    required this.videoId,
    required this.title,
    required this.artist,
  });

  final String videoId;
  final String title;
  final String artist;

  /// Canonical watch URL used as the persistent task source.
  String get watchUrl => 'https://www.youtube.com/watch?v=$videoId';
}

/// A resolved, directly downloadable audio stream for a video.
class YouTubeAudioStream {
  const YouTubeAudioStream({required this.url, required this.extension});

  /// Time-limited direct stream URL (valid for hours, not days).
  final String url;

  /// Container extension: m4a, webm, mp3 or opus.
  final String extension;
}

/// One track of a playlist (title/artist known, audio resolved lazily).
class YouTubePlaylistEntry {
  const YouTubePlaylistEntry({
    required this.videoId,
    required this.title,
    required this.artist,
  });

  final String videoId;
  final String title;
  final String artist;

  /// Canonical watch URL used as the persistent task source.
  String get watchUrl => 'https://www.youtube.com/watch?v=$videoId';
}

class YouTubeException implements Exception {
  const YouTubeException(this.message);
  final String message;

  @override
  String toString() => 'YouTubeException: $message';
}

/// Resolves YouTube watch/playlist URLs into titles and directly
/// downloadable audio streams using YouTube's public Innertube API
/// (ANDROID client — no API key required).
///
/// Deliberately minimal: public, non-membership videos only. Members-only,
/// age-restricted or sign-in-gated content is rejected with a clear error.
class YouTubeResolver {
  YouTubeResolver({
    HttpClient? client,
    String? baseUrl,
    List<Duration> retryBackoffs = const [Duration(seconds: 2), Duration(seconds: 6)],
  })  : _client = client ?? HttpClient()..connectionTimeout = _connectTimeout,
         _baseUrl = baseUrl ?? 'https://www.youtube.com/youtubei/v1/',
         _retryBackoffs = retryBackoffs;

  static const _connectTimeout = Duration(seconds: 15);
  static const _requestTimeout = Duration(seconds: 30);
  static const _clientName = 'ANDROID';

  /// Known-good ANDROID client versions, newest first. YouTube's edge
  /// servers reject stale client versions with HTTP 400, so we rotate
  /// through these on retry and remember whichever one works.
  static const List<String> _clientVersions = ['20.34.39', '20.10.38', '20.34.37'];

  final HttpClient _client;
  final String _baseUrl;

  /// Session cache: the last version that answered 200.
  String _workingVersion = _clientVersions.first;

  final List<Duration> _retryBackoffs;

  // ---------------------------------------------------------------- URLs

  // --------------------------------------------------------------- static

  static bool isYouTubeUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null) return false;
    return host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'm.youtube.com' ||
        host == 'music.youtube.com' ||
        host == 'youtu.be' ||
        host == 'www.youtube-nocookie.com';
  }

  /// 11-char video id, or null.
  static String? videoIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !isYouTubeUrl(url)) return null;
    if (uri.host == 'youtu.be') {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      return _isVideoId(id) ? id : null;
    }
    final v = uri.queryParameters['v'];
    if (v != null && _isVideoId(v)) return v;
    final segs = uri.pathSegments;
    for (final prefix in const ['shorts', 'live', 'embed']) {
      if (segs.length >= 2 && segs[0] == prefix && _isVideoId(segs[1])) {
        return segs[1];
      }
    }
    return null;
  }

  /// 34-char playlist id (`PL…`), or null.
  /// Canonical URL for duplicate detection: YouTube watch URLs become
  /// `https://www.youtube.com/watch?v=<id>` and playlists
  /// `https://www.youtube.com/playlist?list=<id>`, so format variants
  /// (`youtu.be`, extra query parameters, `music.youtube.com`) compare
  /// equal. Any other URL passes through trimmed.
  static String canonicalUrl(String url) {
    final trimmed = url.trim();
    final video = videoIdFromUrl(trimmed);
    if (video != null) return 'https://www.youtube.com/watch?v=$video';
    final playlist = playlistIdFromUrl(trimmed);
    if (playlist != null) {
      return 'https://www.youtube.com/playlist?list=$playlist';
    }
    return trimmed;
  }

  static String? playlistIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !isYouTubeUrl(url)) return null;
    final list = uri.queryParameters['list'];
    if (list != null && _isPlaylistId(list)) return list;
    return null;
  }

  static bool _isVideoId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id);

  static bool _isPlaylistId(String id) =>
      RegExp(r'^PL[A-Za-z0-9_-]{32}$').hasMatch(id);

  // ------------------------------------------------------------ endpoints

  Future<String> _readAll(HttpClientResponse res) async {
    final chunks = <List<int>>[];
    var total = 0;
    await for (final chunk in res) {
      total += chunk.length;
      if (total > 4 * 1024 * 1024) {
        await res.drain();
        throw const YouTubeException('YouTube response too large');
      }
      chunks.add(chunk);
    }
    return String.fromCharCodes(chunks.expand((c) => c));
  }

  /// POSTs to an Innertube endpoint, rotating client versions with backoff
  /// when the server rejects the request (HTTP 400 is YouTube's way of
  /// saying "stale client version" or "slow down").
  Future<Map<String, dynamic>> _post(
      String endpoint, Map<String, dynamic> body) async {
    final versions = [
      _workingVersion,
      for (final v in _clientVersions) 
        if (v != _workingVersion) v
    ];
    String? lastError;
    var attempt = 0;
    for (final version in versions) {
      try {
        final data = await _postOnce(endpoint, body, version);
        _workingVersion = version;
        return data;
      } on YouTubeException catch (e) {
        lastError = e.message;
      } catch (e) {
        lastError = '$e';
      }
      if (attempt < versions.length - 1) {
        final backoff = attempt < _retryBackoffs.length
            ? _retryBackoffs[attempt]
            : const Duration(seconds: 6);
        await Future<void>.delayed(backoff);
      }
      attempt++;
    }
    throw YouTubeException('YouTube request failed ($lastError)');
  }

  Future<Map<String, dynamic>> _postOnce(
      String endpoint, Map<String, dynamic> body, String version) async {
    final uri = Uri.parse('$_baseUrl$endpoint?prettyPrint=0');
    final req =
        await _client.postUrl(uri).timeout(_requestTimeout);
    req.headers.contentType = ContentType.json;
    req.headers.set('User-Agent',
        'com.google.android.youtube/$version (Linux; U; Android 14) gzip');
    final payload = Map<String, dynamic>.from(body)
      ..['context'] = {
        'client': {
          'clientName': _clientName,
          'clientVersion': version,
          'hl': 'en',
          'gl': 'US',
        }
      };
    req.write(jsonEncode(payload));
    final res = await req.close().timeout(_requestTimeout);
    final text = await _readAll(res);
    if (res.statusCode != 200) {
      throw YouTubeException(_errorSummary(res.statusCode, text));
    }
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      throw YouTubeException('Unreadable YouTube response: $e');
    }
  }

  /// Extracts a human-readable reason from a YouTube error body.
  static String _errorSummary(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final message = err['message'] as String?;
          if (message != null && message.isNotEmpty) {
            return 'HTTP $status: $message';
          }
        }
      }
    } catch (_) {
      // fall through
    }
    return 'HTTP $status';
  }

  /// Resolves a single video: title, artist and a direct audio stream URL.
  Future<({YouTubeVideoRef ref, YouTubeAudioStream stream})>
      resolveVideo(String url) async {
    final videoId = videoIdFromUrl(url);
    if (videoId == null) {
      throw const YouTubeException('Not a recognizable YouTube video URL');
    }
    final data = await _post('player', {'videoId': videoId});

    final status = data['playabilityStatus']?['status'] as String?;
    if (status != 'OK') {
      throw YouTubeException(_explainStatus(status));
    }

    final details = data['videoDetails'] as Map<String, dynamic>? ?? {};
    final title = (details['title'] as String?)?.trim() ?? 'Unknown title';
    final artist = (details['author'] as String?)?.trim() ?? 'Unknown Artist';

    final formats = (data['streamingData'] as Map<String, dynamic>?)?['adaptiveFormats']
            as List<dynamic>? ??
        const <dynamic>[];
    final stream = _pickAudio(formatItems(formats));
    if (stream == null) {
      throw const YouTubeException(
          'No downloadable audio stream available for this video');
    }
    AppLogger.info('Resolved YouTube video $videoId -> $title ($artist)',
        tag: 'youtube');
    return (ref: YouTubeVideoRef(videoId: videoId, title: title, artist: artist), stream: stream);
  }

  /// Resolves a playlist into its tracks (first [limit] entries, following
  /// continuations as needed).
  Future<List<YouTubePlaylistEntry>> resolvePlaylist(
    String url, {
    int limit = 200,
  }) async {
    final playlistId = playlistIdFromUrl(url);
    if (playlistId == null) {
      throw const YouTubeException('Not a recognizable YouTube playlist URL');
    }
    final entries = <YouTubePlaylistEntry>[];
    String? token;
    final browseId = 'VL$playlistId';

    do {
      final body = <String, dynamic>{'browseId': browseId};
      if (token != null) body['continuation'] = token;
      final data =
          await _post(token == null ? 'browse' : 'next', body);

      final page = _scanPlaylistPage(data);
      if (page.alert != null) {
        throw YouTubeException(page.alert!);
      }
      entries.addAll(page.entries);
      token = page.continuation;
    } while (token != null && entries.length < limit);

    if (entries.isEmpty) {
      throw const YouTubeException(
          'Playlist is empty or could not be read');
    }
    final result = entries.length > limit ? entries.sublist(0, limit) : entries;
    AppLogger
        .info('Resolved YouTube playlist $playlistId -> ${result.length} tracks', tag: 'youtube');
    return result;
  }

  // -------------------------------------------------------------- helpers

  static Iterable<Map<String, dynamic>> formatItems(List<dynamic> raw) =>
      raw.whereType<Map<String, dynamic>>();

  /// Picks the best directly downloadable audio-only stream:
  /// m4a > mp3 > webm/opus, highest bitrate first.
  static YouTubeAudioStream? _pickAudio(
      Iterable<Map<String, dynamic>> formats) {
    int rank(String mime) {
      if (mime.startsWith('audio/mp4')) return 0;
      if (mime.startsWith('audio/mpeg')) return 1;
      if (mime.startsWith('audio/webm')) return 2;
      if (mime.contains('opus')) return 3;
      return 4;
    }

    String ext(String mime) {
      if (mime.startsWith('audio/mp4')) return 'm4a';
      if (mime.startsWith('audio/mpeg')) return 'mp3';
      if (mime.startsWith('audio/webm')) return 'webm';
      return 'opus';
    }

    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final f in formats) {
      final mime = f['mimeType'] as String? ?? '';
      if (!mime.startsWith('audio')) continue;
      final url = f['url'] as String?;
      if (url == null || url.isEmpty) continue; // ciphered: unsupported
      final bitrate = (f['averageBitrate'] as num?)?.toInt() ?? 0;
      final score = rank(mime) * 100000 + bitrate;
      if (score > bestScore) {
        bestScore = score;
        best = f;
      }
    }
    if (best == null) return null;
    final mime = best['mimeType'] as String;
    return YouTubeAudioStream(url: best['url'] as String, extension: ext(mime));
  }

  static String _explainStatus(String? status) {
    switch (status) {
      case 'LOGIN_REQUIRED':
        return 'This video requires YouTube sign-in';
      case 'UNPLAYABLE':
        return 'This video is unavailable to download';
      case 'ERROR':
        return 'YouTube could not process this video';
      default:
        return 'YouTube video unavailable (${status ?? 'unknown status'})';
    }
  }

  static _Page _scanPlaylistPage(Map<String, dynamic> data) {
    _Page? page;
    void walk(dynamic node) {
      if (node is Map<String, dynamic>) {
        final alert = node['alertRenderer'];
        if (alert is Map<String, dynamic>) {
          final text = (alert['text'] as Map<String, dynamic>?)?['runs']
                  as List<dynamic>? ??
              const [];
          final message = text
              .whereType<Map<String, dynamic>>()
              .map((r) => r['text'] as String? ?? '')
              .join();
          if (message.isNotEmpty) {
            page = _Page(entries: const [], continuation: null,
                alert: 'Playlist unavailable: $message');
            return;
          }
        }
        final video = node['playlistVideoRenderer'];
        if (video is Map<String, dynamic>) {
          final id = video['videoId'] as String?;
          if (id != null && _isVideoId(id)) {
            final p = page ?? _Page(entries: [], continuation: null, alert: null);
            page = p;
            p.entries.add(YouTubePlaylistEntry(
              videoId: id,
              title: _firstText(video['title']) ?? 'Unknown title',
              artist: _firstText(video['ownerText']) ?? 'Unknown Artist',
            ));
          }
        }
        // Newer API shape: lockupViewModel.
        final lockup = node['lockupViewModel'];
        if (lockup is Map<String, dynamic>) {
          final id = lockup['contentId'] as String?;
          if (id != null && _isVideoId(id)) {
            final p = page ?? _Page(entries: [], continuation: null, alert: null);
            page = p;
            final metadata =
                (lockup['metadata'] as Map<String, dynamic>?)?['lockupMetadataViewModel']
                    as Map<String, dynamic>?;
            final title = metadata == null
                ? 'Unknown title'
                : (metadata['title'] as Map<String, dynamic>?)?['content'] as String? ??
                    'Unknown title';
            p.entries
                .add(YouTubePlaylistEntry(videoId: id, title: title, artist: 'Unknown Artist'));
          }
        }
        final cont = node['continuationItemRenderer'];
        if (cont is Map<String, dynamic>) {
          final token = (cont['continuationEndpoint'] as Map<String, dynamic>?)?['continuation'];
          if (token is String && token.isNotEmpty) {
            final p = page ?? _Page(entries: [], continuation: null, alert: null);
            page = p;
            p.continuation = token;
          }
        }
        node.values.forEach(walk);
      } else if (node is List<dynamic>) {
        node.forEach(walk);
      }
    }

    walk(data);
    return page ?? _Page(entries: [], continuation: null, alert: null);
  }

  /// Extracts the first plain-text run of a `{"runs":[{"text":...}]}` field.
  static String? _firstText(dynamic field) {
    if (field is! Map<String, dynamic>) return null;
    final runs = field['runs'] as List<dynamic>?;
    if (runs == null) return null;
    final first = runs.whereType<Map<String, dynamic>>().firstOrNull;
    return first?['text'] as String?;
  }
}

class _Page {
  _Page({
    required this.entries,
    required this.continuation,
    required this.alert,
  });
  final List<YouTubePlaylistEntry> entries;
  String? continuation;
  final String? alert;
}
