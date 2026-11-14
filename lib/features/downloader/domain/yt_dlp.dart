import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/platform/platform_info.dart';

/// Error from the yt-dlp backend (listing, download, setup).
class YtDlpException implements Exception {
  const YtDlpException(this.message);

  final String message;

  @override
  String toString() => 'YtDlpException: $message';
}

/// One entry of a flat listing (single video or playlist).
class YtDlpEntry {
  const YtDlpEntry({required this.id, required this.title, this.channel});

  /// YouTube video id.
  final String id;
  final String title;
  final String? channel;

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';
}

/// One parsed progress line of a running download.
class YtDlpProgress {
  const YtDlpProgress({required this.fraction, this.etaSeconds, required this.line});

  /// 0.0..1.0 (0 when unknown).
  final double fraction;
  final int? etaSeconds;
  final String line;
}

/// Abstraction over the yt-dlp execution strategy.
///
/// * Android: runs the bundled yt-dlp (private Python runtime shipped in
///   the AAR, via the youtubedl-android library) through a method channel.
/// * Desktop: downloads the official standalone binary once (pinned
///   version + SHA-256) into the app data dir and spawns it as a process.
///
/// Plain HTTP is not an option: since 2024 YouTube's `videoplayback` URLs
/// are token-protected (PO tokens / GVS) and reject any client that does
/// not perform the attestation dance — which is exactly what yt-dlp does.
abstract class YtDlpBackend {
  /// One-time preparation: asset extraction (Android) or binary
  /// download + checksum verification (desktop).
  Future<void> ensureReady();

  /// Flat listing of a video or playlist (no media downloaded).
  Future<List<YtDlpEntry>> list(String url);

  /// Downloads the best audio stream for [url] (m4a preferred) into
  /// [workDir] and returns the final file path.
  ///
  /// [processKey] identifies the run so [cancel] can stop it.
  /// [shouldCancel], when provided, is polled on progress; when it
  /// returns true the backend kills the process and throws
  /// [YtDlpException] with the message 'cancelled'.
  Future<String> downloadAudio({
    required String url,
    required String workDir,
    required String processKey,
    required String expectedId,
    bool Function()? shouldCancel,
    void Function(YtDlpProgress)? onProgress,
  });

  /// Kills the run identified by [processKey], if any.
  Future<void> cancel(String processKey);

  /// Releases platform resources.
  void close();
}

/// Picks the right backend for the current platform.
YtDlpBackend createYtDlpBackend({required String appRoot}) {
  if (PlatformInfo.isAndroid) {
    return AndroidYtDlp();
  }
  return DesktopYtDlp(binDir: p.join(appRoot, 'bin', 'yt-dlp'));
}

// --------------------------------------------------------------------------
// Shared JSON parsing
// --------------------------------------------------------------------------

/// Parses yt-dlp's `--flat-playlist --dump-json` output. A single video
/// yields one object; a playlist yields `{"_type": "playlist", ...}` with
/// an `entries` list.
List<YtDlpEntry> parseYtDlpListing(String stdout) {
  final decoded = jsonDecode(stdout);
  List<Map<String, dynamic>> raw;
  if (decoded is List) {
    // --flat-playlist emits a top-level array of entry objects.
    raw = decoded.whereType<Map<String, dynamic>>().toList();
  } else if (decoded is Map<String, dynamic>) {
    final entries = decoded['entries'];
    raw = entries is List
        ? entries.whereType<Map<String, dynamic>>().toList()
        : [decoded];
  } else {
    raw = const [];
  }
  return raw
      .where((e) => e['id'] is String && (e['id'] as String).isNotEmpty)
      .map((e) => YtDlpEntry(
            id: e['id'] as String,
            title: (e['title'] as String?) ?? e['id'] as String,
            channel: e['uploader'] as String?,
          ))
      .toList();
}

/// Picks the newly created audio file for [expectedId] in [dir].
Future<String?> findDownloadedFile(
    String dir, String expectedId, Set<String> before) async {
  final dirObj = Directory(dir);
  if (!dirObj.existsSync()) return null;
  const audioExts = {'mp3', 'm4a', 'ogg', 'opus', 'webm', 'flac', 'wav', 'aac', 'mp4'};
  for (final entity in dirObj.listSync()) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith('$expectedId.')) continue;
    final ext = p.extension(name).toLowerCase().replaceAll('.', '');
    if (!audioExts.contains(ext)) continue;
    if (before.contains(name)) continue;
    return entity.path;
  }
  return null;
}

Future<Set<String>> _listDir(String dir) async {
  final dirObj = Directory(dir);
  if (!dirObj.existsSync()) return <String>{};
  return dirObj
      .listSync()
      .map((e) => p.basename(e.path))
      .toSet();
}

// --------------------------------------------------------------------------
// Android: bundled runtime via method channel
// --------------------------------------------------------------------------

class AndroidYtDlp implements YtDlpBackend {
  static const _channelName = 'yose_ue/youtube_dl';
  static const _progressChannelName = 'yose_ue/youtube_dl/progress';
  static const _format = 'bestaudio[ext=m4a]/bestaudio';

  final MethodChannel _channel = const MethodChannel(_channelName);
  final _listeners = <String, void Function(YtDlpProgress)>{};
  StreamSubscription<dynamic>? _progressSub;

  @override
  Future<void> ensureReady() async {
    await _channel.invokeMethod('init');
  }

  @override
  Future<List<YtDlpEntry>> list(String url) async {
    await ensureReady();
    try {
      final out = await _channel.invokeMethod<String>('list', {'url': url});
      if (out == null || out.isEmpty) {
        throw const YtDlpException('YouTube returned no entries');
      }
      return parseYtDlpListing(out);
    } on PlatformException catch (e) {
      throw YtDlpException(_cleanMessage(e));
    }
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
    await ensureReady();
    _ensureProgressListening();
    Directory(workDir).createSync(recursive: true);
    final before = await _listDir(workDir);
    _listeners[processKey] = (p) {
      if (shouldCancel?.call() == true) {
        cancel(processKey);
      }
      onProgress?.call(p);
    };
    try {
      await _channel.invokeMethod('download', {
        'url': url,
        'workDir': workDir,
        'processKey': processKey,
        'format': _format,
      });
    } on PlatformException catch (e) {
      throw YtDlpException(_cleanMessage(e));
    } finally {
      _listeners.remove(processKey);
    }
    final path = await findDownloadedFile(workDir, expectedId, before);
    if (path == null) {
      throw const YtDlpException('Download finished but no audio file was produced');
    }
    return path;
  }

  @override
  Future<void> cancel(String processKey) async {
    try {
      await _channel.invokeMethod('cancel', {'processKey': processKey});
    } on PlatformException catch (e) {
      AppLogger.warning('yt-dlp cancel failed: ${e.message}', tag: 'yt-dlp');
    }
  }

  void _ensureProgressListening() {
    _progressSub ??= const EventChannel(_progressChannelName)
        .receiveBroadcastStream()
        .listen((event) {
      if (event is Map) {
        final key = event['key'] as String?;
        final listener = key != null ? _listeners[key] : null;
        if (listener == null) return;
        final progress = (event['progress'] as num?)?.toDouble() ?? -1;
        final eta = (event['eta'] as num?)?.toInt() ?? -1;
        listener(YtDlpProgress(
          fraction: progress.clamp(0.0, 1.0),
          etaSeconds: eta >= 0 ? eta : null,
          line: (event['line'] as String?) ?? '',
        ));
      }
    }, onError: (Object e) {
      AppLogger.warning('yt-dlp progress stream error: $e', tag: 'yt-dlp');
    });
  }

  String _cleanMessage(PlatformException e) {
    // The Kotlin side already carries yt-dlp's stderr in `message`.
    final message = e.message ?? 'yt-dlp failed';
    final tail = _tail(message, 400);
    return e.code == 'cancelled' ? 'cancelled' : tail;
  }

  @override
  void close() {
    _progressSub?.cancel();
    _progressSub = null;
    _listeners.clear();
  }
}

/// Last [max] characters of [s] (yt-dlp's error lines are at the tail).
String _tail(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : '…' + t.substring(t.length - max);
}

// --------------------------------------------------------------------------
// Desktop: official standalone binary (pinned, checksummed)
// --------------------------------------------------------------------------

class DesktopYtDlp implements YtDlpBackend {
  DesktopYtDlp({required String binDir}) : _binDir = binDir;

  /// Pinned release. Update [sha256] together with the URL when bumping.
  static const _version = '2026.10.26';
  static const _base =
      'https://github.com/yt-dlp/yt-dlp/releases/download/$_version/';

  final String _binDir;
  final _processes = <String, Process>{};
  HttpClient? _client;

  ({String name, String url, String sha256}) get _binaryInfo {
    if (PlatformInfo.isMacOS) {
      return (name: 'yt-dlp_macos', url: '${_base}yt-dlp_macos',
          sha256: '0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa');
    }
    if (PlatformInfo.isWindows) {
      return (name: 'yt-dlp.exe', url: '${_base}yt-dlp.exe',
          sha256: 'f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d');
    }
    // Linux: zipimport launcher; needs a system python3 >= 3.11.
    return (name: 'yt-dlp', url: '${_base}yt-dlp',
        sha256: 'e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3');
  }

  String get _binaryPath => p.join(_binDir, _binaryInfo.name);

  @override
  Future<void> ensureReady() async {
    final binary = File(_binaryPath);
    if (binary.existsSync()) return;
    if (PlatformInfo.isLinux) {
      await _checkPython3();
    }
    binary.parent.createSync(recursive: true);
    final tmp = File('${_binaryPath}.download');
    AppLogger.info('Downloading yt-dlp $_version (${_binaryInfo.name})',
        tag: 'yt-dlp');
    final client = _client ?? HttpClient()..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    try {
      final req = await client.getUrl(Uri.parse(_binaryInfo.url));
      final res = await req.close().timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) {
        await res.drain();
        throw YtDlpException('yt-dlp download failed: HTTP ${res.statusCode}');
      }
      final out = await tmp.open(mode: FileMode.write);
      final bytes = BytesBuilder();
      await for (final chunk in res) {
        bytes.add(chunk);
        await out.writeFrom(chunk);
      }
      await out.close();
      final sha = sha256.convert(bytes.toBytes()).toString();
      if (sha != _binaryInfo.sha256) {
        await tmp.delete();
        throw const YtDlpException('yt-dlp checksum mismatch (corrupt download)');
      }
      await tmp.rename(_binaryPath);
      if (PlatformInfo.isLinux || PlatformInfo.isMacOS) {
        await Process.run('chmod', ['+x', _binaryPath]);
      }
      AppLogger.info('yt-dlp $_version installed at $_binaryPath', tag: 'yt-dlp');
    } on YtDlpException {
      rethrow;
    } catch (e) {
      try {
        await tmp.delete();
      } catch (_) {}
      throw YtDlpException('yt-dlp setup failed: $e');
    }
  }

  Future<void> _checkPython3() async {
    try {
      final result = await Process.run('python3', ['--version']);
      final version = '${result.stdout}${result.stderr}'.trim();
      // Python 3.11+ is required by the pinned zipimport build.
      final ok = RegExp(r'Python 3\.(1[1-9]|[2-9]\d)').hasMatch(version);
      if (!ok) {
        throw YtDlpException(
            'Linux needs python3 >= 3.11 to run yt-dlp (found: ${version.isEmpty ? 'none' : version})');
      }
    } on YtDlpException {
      rethrow;
    } catch (_) {
      throw const YtDlpException('Linux needs python3 to run yt-dlp (not found)');
    }
  }

  List<String> get _command {
    final binary = _binaryPath;
    return PlatformInfo.isLinux ? ['python3', binary] : [binary];
  }

  @override
  Future<List<YtDlpEntry>> list(String url) async {
    await ensureReady();
    try {
      final result = await Process.run(
        _command.first,
        [..._command.skip(1), '--flat-playlist', '--dump-json', '--no-warnings', url],
      ).timeout(const Duration(minutes: 3));
      if (result.exitCode != 0) {
        final err = _tail(result.stderr as String, 400);
        throw YtDlpException(err.isEmpty
            ? 'yt-dlp listing failed (exit ${result.exitCode})'
            : err);
      }
      final entries = parseYtDlpListing(result.stdout as String);
      if (entries.isEmpty) {
        throw const YtDlpException('YouTube returned no entries');
      }
      return entries;
    } on YtDlpException {
      rethrow;
    } catch (e) {
      throw YtDlpException('yt-dlp listing failed: $e');
    }
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
    await ensureReady();
    Directory(workDir).createSync(recursive: true);
    final before = await _listDir(workDir);
    final process = await Process.start(_command.first, [
      ..._command.skip(1),
      '-f',
      'bestaudio[ext=m4a]/bestaudio',
      '--no-part',
      '--no-playlist',
      '--restrict-filenames',
      '--no-warnings',
      '-o',
      '$workDir/%(id)s.%(ext)s',
      url,
    ]);
    _processes[processKey] = process;
    var cancelled = false;
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (shouldCancel?.call() == true) {
        cancelled = true;
        process.kill(ProcessSignal.sigkill);
        return;
      }
      _emitProgress(line, onProgress);
    });
    final stderrBuf = StringBuffer();
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderrBuf.writeln(line));
    final code = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    _processes.remove(processKey);
    if (cancelled || shouldCancel?.call() == true) {
      throw const YtDlpException('cancelled');
    }
    if (code != 0) {
      final err = _tail(stderrBuf.toString(), 400);
      throw YtDlpException(err.isEmpty ? 'yt-dlp failed (exit $code)' : err);
    }
    final path = await findDownloadedFile(workDir, expectedId, before);
    if (path == null) {
      throw const YtDlpException('Download finished but no audio file was produced');
    }
    return path;
  }

  static final _progressRe =
      RegExp(r'\[download\]\s+(\d+\.\d)%.*?ETA\s+(\d+):(\d+)');

  void _emitProgress(String line, void Function(YtDlpProgress)? onProgress) {
    if (onProgress == null) return;
    final m = _progressRe.firstMatch(line);
    if (m == null) return;
    onProgress(YtDlpProgress(
      fraction: double.parse(m.group(1)!).clamp(0.0, 100.0) / 100.0,
      etaSeconds:
          int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!),
      line: line,
    ));
  }

  @override
  Future<void> cancel(String processKey) async {
    _processes[processKey]?.kill(ProcessSignal.sigkill);
  }

  @override
  void close() {
    for (final process in _processes.values) {
      process.kill(ProcessSignal.sigkill);
    }
    _processes.clear();
    _client?.close(force: true);
    _client = null;
  }
}
