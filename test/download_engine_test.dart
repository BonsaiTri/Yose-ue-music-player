// Milestone 4 tests: the download engine executes queued tasks end-to-end
// against a real local HTTP server: queue -> prepare -> download ->
// process -> validate -> complete, plus failure, cancel-in-flight, retry
// and non-web URL handling.
//
// Plain `test()` (not `testWidgets`): real async I/O is allowed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/core/services/artwork_service.dart';
import 'package:music_player/core/services/file_lock_manager.dart';
import 'package:music_player/core/services/file_service.dart';
import 'package:music_player/core/services/metadata_service.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/download_repository.dart';
import 'package:music_player/database/repositories/library_repository.dart';
import 'package:music_player/features/downloader/domain/download_engine.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';
import 'package:music_player/features/downloader/domain/youtube_resolver.dart';
import 'package:music_player/features/downloader/presentation/downloads_screen.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';

/// 1 s of silence as a valid WAV (16-bit PCM mono).
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
  u16(2);
  u16(16);
  ascii('data');
  u32(dataLen);
  b.addByte(0); // 1 zero byte flushed below to keep length exact
  final zeros = Uint8List(dataLen - 1);
  b.add(zeros);
  return b.toBytes();
}

Future<DownloadTask> _waitUntil(
  DownloadRepository downloads,
  String id,
  Set<DownloadTaskStatus> terminal, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final task = await downloads.byId(id);
    if (task != null && terminal.contains(task.status)) return task;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final task = await downloads.byId(id);
  fail('Task $id never reached one of $terminal (last: '
      '${task == null ? 'missing' : task.status.name})');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory temp;
  late FileService files;
  late AppDatabase db;
  late DownloadRepository downloads;
  late ImportService importer;
  late DownloadEngine engine;
  late HttpServer server;
  late int port;

  List<int>? serveBytes; // per-test body
  Map<String, List<int>>? routeBytes; // per-path bodies (playlist tests)
  Map<String, Map<String, dynamic>>? routeJson; // per-path JSON (YouTube tests)

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    serveBytes = null;
    server.listen((req) async {
      final jsonBody = routeJson?[req.uri.path];
      if (jsonBody != null) {
        // Drain any POST body (Innertube calls are POSTs).
        await req.drain();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(jsonBody));
        await req.response.close();
        return;
      }
      final body = routeBytes?[req.uri.path] ?? serveBytes;
      if (body == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = req.uri.path.endsWith('.m3u8') ||
              req.uri.path.endsWith('.m3u')
          ? ContentType.parse('audio/x-mpegurl')
          : ContentType.parse('audio/wav');
      req.response.contentLength = body.length;
      // Serve in small chunks with a small delay so the transfer is slow
      // enough to observe in-flight cancel.
      const chunk = 1024;
      for (var i = 0; i < body.length; i += chunk) {
        req.response.add(body.sublist(i,
            i + chunk > body.length ? body.length : i + chunk));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await req.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() async {
    routeBytes = null;
    routeJson = null;
    temp = await Directory.systemTemp.createTemp('dl_engine_');
    files = FileService(temp.path);
    await files.ensureDirectories();
    db = AppDatabase.withFile(
        File(p.join(files.databaseDir, 'test.sqlite')));
    downloads = DownloadRepository(db);
    final metadata = MetadataService(binDir: files.binDir);
    final artwork = ArtworkService(db, files);
    final locks = FileLockManager();
    importer = ImportService(
      files: files,
      metadata: metadata,
      artwork: artwork,
      tracks: TrackRepository(db),
      artists: ArtistRepository(db),
      albums: AlbumRepository(db),
      genres: GenreRepository(db),
      locks: locks,
      db: db,
    );
    engine = DownloadEngine(downloads: downloads, files: files, importer: importer);
  });

  tearDown(() async {
    await engine.stop();
    await db.close();
    await temp.delete(recursive: true);
  });

  test('queue -> download -> process -> validate -> complete, track registered',
      () async {
    final wav = _wavBytes();
    serveBytes = wav;
    final url = 'http://127.0.0.1:$port/song.wav';
    final task = await engine.queue(url: url, title: 'Wav Song', artist: 'Wav Artist');
    await engine.start();

    final done = await _waitUntil(downloads, task.id, {DownloadTaskStatus.completed});
    expect(done.status, DownloadTaskStatus.completed);
    expect(done.progress, 1.0);
    expect(done.bytesDone, wav.length);
    expect(done.bytesExpected, wav.length);
    expect(done.finalPath, isNotNull);
    final file = File(done.finalPath!);
    expect(file.existsSync(), isTrue);
    expect(await file.length(), wav.length);
    expect(await file.readAsBytes(), wav);
    // Registered into the library with sourceType 'download'.
    expect(done.trackId, isNotNull);
    final track = await (db.select(db.tracks)
          ..where((t) => t.id.equals(done.trackId!)))
        .getSingle();
    expect(track.sourceType, 'download');
    expect(track.filePath, done.finalPath);
    expect(track.title, isNot(''));
    // No abandoned temp file.
    expect(
        Directory(files.tempDir)
            .listSync()
            .where((e) => e.path.endsWith('.part')),
        isEmpty);
  });

  test('HTTP 404 marks the task failed with a clear error', () async {
    serveBytes = null; // 404 for every path
    final url = 'http://127.0.0.1:$port/missing.mp3';
    final task = await engine.queue(url: url, title: 'Missing');
    await engine.start();

    final failed =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.failed});
    expect(failed.status, DownloadTaskStatus.failed);
    expect(failed.error, contains('404'));
    expect(failed.finalPath, isNull);
  });

  test('failed task can be retried and then completes', () async {
    final wav = _wavBytes();
    // Start with the route down, fail, then bring it up and retry.
    serveBytes = null;
    final url = 'http://127.0.0.1:$port/song.wav';
    final task = await engine.queue(url: url, title: 'Retry Song');
    await engine.start();

    final failed =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.failed});
    expect(failed.status, DownloadTaskStatus.failed);

    serveBytes = wav;
    await engine.retry(task.id);
    final done = await _waitUntil(downloads, task.id, {DownloadTaskStatus.completed});
    expect(done.status, DownloadTaskStatus.completed);
    expect(done.error, isNull);
    expect(done.finalPath, isNotNull);
    expect(File(done.finalPath!).existsSync(), isTrue);
  });

  test('cancel while downloading stops the transfer and cleans up', () async {
    final wav = _wavBytes(seconds: 2);
    serveBytes = wav;
    final url = 'http://127.0.0.1:$port/slow.wav';
    final task = await engine.queue(url: url, title: 'Slow Song');
    await engine.start();

    // Wait until the transfer is actually in flight.
    await _waitUntil(downloads, task.id, {DownloadTaskStatus.downloading});
    await engine.cancel(task.id);

    final cancelled =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.cancelled});
    expect(cancelled.status, DownloadTaskStatus.cancelled);
    expect(cancelled.finalPath, isNull);
    // Temp file removed.
    expect(
        Directory(files.tempDir)
            .listSync()
            .where((e) => e.path.endsWith('.part')),
        isEmpty);
  });

  test('cancelling a queued task never starts it', () async {
    serveBytes = _wavBytes();
    final url = 'http://127.0.0.1:$port/queued.wav';
    final task = await engine.queue(url: url, title: 'Queued Song');
    // Cancel before the engine even starts.
    expect(await engine.cancel(task.id), isTrue);
    final t = await downloads.byId(task.id);
    expect(t!.status, DownloadTaskStatus.cancelled);
    await engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final after = await downloads.byId(task.id);
    expect(after!.status, DownloadTaskStatus.cancelled);
  });

  test('non-web URLs fail with a clear error', () async {
    final task = await engine.queue(url: 'ftp://example.com/x.mp3', title: 'Bad URL');
    await engine.start();
    final failed =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.failed});
    expect(failed.error, contains('http or https'));
  });

  test('M3U8 playlist queues every track and they all complete', () async {
    final wav = _wavBytes();
    final playlist = '''
#EXTM3U
#EXTINF:10,Artist A - Track One
/a.wav
#EXTINF:10,Track Two
/b.wav
#EXTINF:10,Artist B - Track Three
http://127.0.0.1:$port/c.wav
#EXTINF:5,
/sub.m3u8
''';
    routeBytes = {
      '/playlist.m3u8': utf8.encode(playlist),
      '/a.wav': wav,
      '/b.wav': wav,
      '/c.wav': wav,
    };
    final summary = await engine
        .queuePlaylist('http://127.0.0.1:$port/playlist.m3u8');
    expect(summary.queued, 3);
    await engine.start();

    // All three tracks complete; the nested playlist is not queued.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    List<DownloadTask> finished;
    do {
      final history = await downloads.history(limit: 50);
      finished = history
          .where((t) => t.status == DownloadTaskStatus.completed)
          .toList();
      if (finished.length >= 3 || !DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (finished.length < 3);
    expect(finished.length, 3);
    final byTitle = {
      for (final t in finished) t.title: t
    };
    expect(byTitle['Track One']!.artist, 'Artist A');
    expect(byTitle['Track Two']!.artist, 'Unknown Artist');
    expect(byTitle['Track Three']!.artist, 'Artist B');
    expect(byTitle['Track One']!.bytesDone, wav.length);
    for (final t in finished) {
      expect(File(t.finalPath!).existsSync(), isTrue);
      expect(t.trackId, isNotNull);
    }
  });

  test('playlist with no playable tracks is rejected', () async {
    routeBytes = {
      '/empty.m3u8': utf8.encode('#EXTM3U\n# nothing here\n'),
    };
    expect(
      engine.queuePlaylist('http://127.0.0.1:$port/empty.m3u8'),
      throwsA(isA<DownloadTaskException>()),
    );
  });

  test('YouTube URL parsing', () async {
    expect(
        YouTubeResolver.videoIdFromUrl('https://www.youtube.com/watch?v=fBgKxsvl6M8'),
        'fBgKxsvl6M8');
    expect(
        YouTubeResolver.videoIdFromUrl('https://youtu.be/fBgKxsvl6M8'),
        'fBgKxsvl6M8');
    expect(
        YouTubeResolver.videoIdFromUrl('https://www.youtube.com/shorts/fBgKxsvl6M8'),
        'fBgKxsvl6M8');
    expect(
        YouTubeResolver.videoIdFromUrl('https://www.youtube.com/embed/fBgKxsvl6M8'),
        'fBgKxsvl6M8');
    expect(
        YouTubeResolver.videoIdFromUrl(
            'https://www.youtube.com/watch?v=fBgKxsvl6M8&list=PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL'),
        'fBgKxsvl6M8');
    expect(
        YouTubeResolver.videoIdFromUrl('https://example.com/watch?v=notatube'),
        isNull);

    expect(
        YouTubeResolver.playlistIdFromUrl(
            'https://www.youtube.com/playlist?list=PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL'),
        'PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL');
    expect(
        YouTubeResolver.playlistIdFromUrl(
            'https://www.youtube.com/watch?v=fBgKxsvl6M8&list=PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL'),
        'PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL');
    expect(
        YouTubeResolver.playlistIdFromUrl('https://www.youtube.com/watch?v=fBgKxsvl6M8'),
        isNull);

    expect(YouTubeResolver.isYouTubeUrl('https://m.youtube.com/watch?v=fBgKxsvl6M8'), isTrue);
    expect(YouTubeResolver.isYouTubeUrl('https://example.com/a.mp3'), isFalse);
  });

  test('a page served with an audio extension is rejected as non-audio',
      () async {
    const html = '<!DOCTYPE html><html><head><title>not a song</title></head>'
        '<body>youtube watch page</body></html>';
    routeBytes = {'/page.mp3': utf8.encode(html)};
    final task =
        await downloads.create(url: 'http://127.0.0.1:$port/page.mp3', title: 'page');
    await engine.start();
    final done =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.failed});
    expect(done.error, contains('not a recognized audio format'));
  });

  test('YouTube playlist URL queues every track with parsed titles',
      () async {
    const pl = 'PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL';
    final fake = _FakeYtDlp(entries: const [
      YtDlpEntry(id: 'aaaaaaaaaaa', title: 'First Song', channel: 'Artist One'),
      YtDlpEntry(id: 'bbbbbbbbbbb', title: 'Second Song', channel: 'Artist Two'),
    ]);
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: fake);
    try {
      final summary =
          await engine.queueYouTube('https://www.youtube.com/playlist?list=$pl');
      expect(summary.queued, 2);
      expect(summary.ignored, 0);
      final queued = await downloads.queued(limit: 10);
      expect(queued.length, 2);
      expect(queued.map((t) => t.title), ['First Song', 'Second Song']);
      expect(queued.map((t) => t.artist), ['Artist One', 'Artist Two']);
      expect(queued.first.url, 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
    } finally {
      await engine.stop();
    }
  });

  test('YouTube playlist that does not exist is rejected clearly', () async {
    final fake = _FakeYtDlp(errorMessage: 'The playlist does not exist.');
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: fake);
    try {
      await expectLater(
          engine.queueYouTube(
              'https://www.youtube.com/playlist?list=PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL'),
          throwsA(isA<DownloadTaskException>()));
    } finally {
      await engine.stop();
    }
  });

  test('YouTube video task downloads audio via yt-dlp and completes',
      () async {
    final fake = _FakeYtDlp(fileBytes: _wavBytes());
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: fake);
    try {
      final task = await downloads.create(
          url: 'https://www.youtube.com/watch?v=fBgKxsvl6M8',
          title: 'All Eyes On Me (Song Only)',
          artist: 'Bo Burnham - Topic');
      await engine.start();
      final done =
          await _waitUntil(downloads, task.id, {DownloadTaskStatus.completed});
      expect(done.finalPath, endsWith('.m4a'));
      expect(done.trackId, isNotNull);
      expect(fake.calls.any((c) => c.startsWith('download')), isTrue);
      final count = await TrackRepository(db).trackCount();
      expect(count, greaterThan(0));
      // The fake reports no listing entries, so the track must be enriched
      // from the task's own title/artist (queue-time data), not a second
      // yt-dlp listing — and definitely not the bare file name.
      final track = (await TrackRepository(db).recentlyAdded()).first;
      expect(track.title, 'All Eyes On Me (Song Only)');
      expect(track.artist, 'Bo Burnham - Topic');
    } finally {
      await engine.stop();
    }
  });

  test('searchYouTube returns yt-dlp search results', () async {
    final fake = _FakeYtDlp(entries: const [
      YtDlpEntry(
          id: '1Rx_p3NW7gQ',
          title: 'All Eyes On Me -- Bo Burnham',
          channel: 'boburnham',
          thumbnail: 'https://i.ytimg.com/vi/1Rx_p3NW7gQ/hqdefault.jpg'),
      YtDlpEntry(id: 'fBgKxsvl6M8', title: 'All Eyes On Me (Song Only)', channel: 'boburnham'),
    ]);
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: fake);
    try {
      final found = await engine.searchYouTube('bo burnham all eyes on me');
      expect(found, hasLength(2));
      expect(found.first.id, '1Rx_p3NW7gQ');
      expect(found.first.title, 'All Eyes On Me -- Bo Burnham');
      expect(
          fake.calls
              .any((c) => c.contains('ytsearch8:bo burnham all eyes on me')),
          isTrue);
    } finally {
      await engine.stop();
    }
  });

  test('searchYouTube respects maxResults and caps it at 20', () async {
    final fake = _FakeYtDlp(entries: const [
      YtDlpEntry(id: 'aaaaaaaaaaa', title: 'A'),
    ]);
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: fake);
    try {
      await engine.searchYouTube('test query', maxResults: 3);
      expect(fake.calls.any((c) => c.contains('ytsearch3:test query')), isTrue);
      await engine.searchYouTube('test query', maxResults: 500);
      expect(fake.calls.any((c) => c.contains('ytsearch20:test query')), isTrue);
    } finally {
      await engine.stop();
    }
  });

  test('searchYouTube rejects empty queries and surfaces backend errors',
      () async {
    final engine = DownloadEngine(
        downloads: downloads, files: files, importer: importer, ytDlp: _FakeYtDlp());
    try {
      await expectLater(engine.searchYouTube('   '),
          throwsA(isA<DownloadTaskException>()));
    } finally {
      await engine.stop();
    }
    final failing = DownloadEngine(
        downloads: downloads,
        files: files,
        importer: importer,
        ytDlp: _FakeYtDlp(errorMessage: 'YouTube search failed.'));
    try {
      await expectLater(failing.searchYouTube('query'),
          throwsA(isA<DownloadTaskException>()));
    } finally {
      await failing.stop();
    }
  });

  group('malformed paste handling', () {
    test('queue rejects URLs with embedded newlines or spaces', () async {
      final engine = DownloadEngine(
          downloads: downloads, files: files, importer: importer);
      try {
        await expectLater(
            engine.queue(
                url: 'https://host.example/a.wav\n{\"title\": \"x\"}',
                title: 'x'),
            throwsA(isA<DownloadTaskException>()));
        await expectLater(
            engine.queue(
                url: 'https://host.example/a b.wav', title: 'x'),
            throwsA(isA<DownloadTaskException>()));
      } finally {
        await engine.stop();
      }
    });

    test('queueYouTube rejects a multi-line paste before touching the backend',
        () async {
      final fake = _FakeYtDlp();
      final engine = DownloadEngine(
          downloads: downloads,
          files: files,
          importer: importer,
          ytDlp: fake);
      try {
        await expectLater(
            engine.queueYouTube(
                'https://youtu.be/Qm8YmI7ceOg\n{"title": "Wellerman"}'),
            throwsA(isA<DownloadTaskException>()));
        expect(fake.calls, isEmpty);
      } finally {
        await engine.stop();
      }
    });

    test('firstUrlLine picks the real link out of messy pastes', () {
      const link = 'https://www.youtube.com/watch?v=Qm8YmI7ceOg';
      // Plain URL passes through untouched.
      expect(DownloadsScreen.firstUrlLine(link), link);
      // URL followed by a JSON metadata line.
      expect(
          DownloadsScreen.firstUrlLine(
              '$link\n{"title": "Wellerman (Sea Shanty)", "thumbnails": []}'),
          link);
      // JSON first, URL on the second line.
      expect(
          DownloadsScreen.firstUrlLine(
              '{"title": "Wellerman"}\n$link'),
          link);
      // Nothing usable.
      expect(DownloadsScreen.firstUrlLine('{"title": "Wellerman"}'), '');
      expect(DownloadsScreen.firstUrlLine('not a link at all'), '');
      // Whitespace around a plain URL is tolerated.
      expect(DownloadsScreen.firstUrlLine('  $link  '), link);
    });
  });

  test('stale client version is rotated away after HTTP 400', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final calls = <String>[];
    server.listen((req) async {
      final chunks = <int>[];
      await for (final c in req) {
        chunks.addAll(c);
      }
      final body = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      final version =
          ((body['context'] as Map<String, dynamic>)['client'] as Map<String, dynamic>)['clientVersion'] as String;
      calls.add(version);
      req.response.headers.contentType = ContentType.json;
      if (version == '20.34.39') {
        req.response.statusCode = 400;
        req.response.write(jsonEncode({
          'error': {'code': 400, 'message': 'Precondition check failed.'}
        }));
      } else {
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'playabilityStatus': {'status': 'OK'},
          'videoDetails': {'title': 'T', 'author': 'A'},
          'streamingData': {
            'adaptiveFormats': [
              {
                'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                'url': 'http://example.invalid/a.m4a',
                'averageBitrate': 128000,
              }
            ]
          }
        }));
      }
      await req.response.close();
    });
    try {
      final resolver = YouTubeResolver(
        baseUrl: 'http://127.0.0.1:${server.port}/youtubei/v1/',
        retryBackoffs: const [Duration(milliseconds: 10)],
      );
      final result =
          await resolver.resolveVideo('https://www.youtube.com/watch?v=fBgKxsvl6M8');
      expect(result.ref.title, 'T');
      expect(result.stream.extension, 'm4a');
      expect(calls.first, '20.34.39'); // preferred version tried first
      expect(calls.length, greaterThanOrEqualTo(2));
      expect(calls.last, isNot('20.34.39')); // rotated to a working version
      // Session cache: a follow-up call goes straight to the working version.
      await resolver.resolveVideo('https://www.youtube.com/watch?v=fBgKxsvl6M8');
      expect(calls.last, calls[1]);
    } finally {
      await server.close(force: true);
    }
  });

  test('when every client version fails the server message is surfaced',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain();
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': {'code': 400, 'message': 'Precondition check failed.'}
      }));
      await req.response.close();
    });
    try {
      final resolver = YouTubeResolver(
        baseUrl: 'http://127.0.0.1:${server.port}/youtubei/v1/',
        retryBackoffs: const [Duration(milliseconds: 1), Duration(milliseconds: 1)],
      );
      await expectLater(
          resolver.resolveVideo('https://www.youtube.com/watch?v=fBgKxsvl6M8'),
          throwsA(isA<YouTubeException>()));
      // Prove the message carries the server's reason:
      try {
        await resolver.resolveVideo('https://www.youtube.com/watch?v=fBgKxsvl6M8');
        fail('expected YouTubeException');
      } on YouTubeException catch (e) {
        expect(e.message, contains('Precondition check failed.'));
        expect(e.message, contains('HTTP 400'));
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('progress is persisted while downloading', () async {
    final wav = _wavBytes(seconds: 2);
    serveBytes = wav;
    final url = 'http://127.0.0.1:$port/progress.wav';
    final task = await engine.queue(url: url, title: 'Progress Song');
    await engine.start();
    // Sample progress while in flight.
    double? seen;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final t = await downloads.byId(task.id);
      if (t == null) break;
      if (t.status == DownloadTaskStatus.downloading && t.progress > 0) {
        seen = t.progress;
        break;
      }
      if (t.status == DownloadTaskStatus.completed ||
          t.status == DownloadTaskStatus.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(seen, isNotNull, reason: 'no in-flight progress sample captured');
    final done =
        await _waitUntil(downloads, task.id, {DownloadTaskStatus.completed});
    expect(done.progress, 1.0);
  });
}

/// Fake yt-dlp backend for engine tests: no network, deterministic output.
class _FakeYtDlp implements YtDlpBackend {
  _FakeYtDlp({this.entries, this.errorMessage, this.fileBytes});

  final List<YtDlpEntry>? entries;
  final String? errorMessage;
  final List<int>? fileBytes;
  final calls = <String>[];

  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<YtDlpEntry>> list(String url) async {
    calls.add('list $url');
    if (errorMessage != null) throw YtDlpException(errorMessage!);
    return entries ?? const [];
  }

  @override
  Future<String> downloadAudio({
    required String url,
    required String workDir,
    required String processKey,
    required String expectedId,
    bool Function()? shouldCancel,
    void Function(YtDlpProgress)? onProgress,
  }) async {
    calls.add('download $url');
    onProgress?.call(const YtDlpProgress(fraction: 0.5, line: '[download] 50.0%'));
    // Real backends create the work dir themselves; mirror that contract.
    Directory(workDir).createSync(recursive: true);
    final out = File(p.join(workDir, '$expectedId.m4a'));
    await out.writeAsBytes(fileBytes ?? _wavBytes());
    return out.path;
  }

  @override
  Future<void> cancel(String processKey) async {}

  @override
  void close() {}
}
