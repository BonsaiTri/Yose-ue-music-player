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

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    serveBytes = null;
    server.listen((req) async {
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
