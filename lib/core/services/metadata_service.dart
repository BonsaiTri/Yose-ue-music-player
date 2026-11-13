import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:just_audio/just_audio.dart';

import 'package:music_player/core/errors/app_exceptions.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/platform/platform_info.dart';

/// Receives the single digest emitted by a chunked [Hash] conversion.
class _DigestSink implements Sink<Digest> {
  _DigestSink(this._completer);

  final Completer<Digest> _completer;

  @override
  void add(Digest value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  @override
  void close() {}
}

/// Result of decoding audio-file metadata.
class ExtractedMetadata {
  const ExtractedMetadata({
    required this.durationMs,
    required this.format,
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.releaseYear,
    this.trackNumber,
    this.discNumber,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.artworkBytes,
    this.artworkMime,
  });

  final int durationMs;
  final String format;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? releaseYear;
  final int? trackNumber;
  final int? discNumber;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final List<int>? artworkBytes;
  final String? artworkMime;
}

/// Extracts metadata from local audio files.
///
/// Primary path: ffprobe (bundled binary when shipped, system ffprobe
/// otherwise). Fallback: just_audio for duration plus filename-derived
/// title, when no probe is available.
class MetadataService {
  MetadataService({required this.binDir});

  /// Extracted native dependency directory under the app data root.
  final String binDir;

  String? _probePath;
  bool _probeChecked = false;

  /// Locates an ffprobe executable (bundled first, then PATH).
  Future<String?> resolveProbe() async {
    if (_probeChecked) return _probePath;
    _probeChecked = true;
    if (PlatformInfo.isDesktop) {
      final os = PlatformInfo.name.toLowerCase();
      final bundled = '$binDir/$os/${PlatformInfo.arch}/ffprobe';
      if (File(bundled).existsSync()) {
        _probePath = bundled;
        return bundled;
      }
    }
    try {
      final result = await Process.run('ffprobe', ['-version']);
      if (result.exitCode == 0) {
        _probePath = 'ffprobe';
      }
    } catch (_) {
      // not on PATH
    }
    return _probePath;
  }

  Future<ExtractedMetadata> extract(String path) async {
    final probe = await resolveProbe();
    if (probe != null) {
      try {
        return await _extractWithProbe(probe, path);
      } catch (e) {
        AppLogger.warning('ffprobe failed for $path ($e); falling back', tag: 'metadata');
      }
    }
    return _extractFallback(path);
  }

  Future<ExtractedMetadata> _extractWithProbe(String probe, String path) async {
    final result = await Process.run(probe, [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      path,
    ]);
    if (result.exitCode != 0) {
      throw MetadataException('ffprobe exited ${result.exitCode}: ${result.stderr}');
    }
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final format = (json['format'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tags = (format['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final streams = (json['streams'] as List?) ?? const [];

    Duration duration = Duration.zero;
    int? bitrate, sampleRate, channels;
    String formatName = 'unknown';
    bool hasVideoStream = false;
    for (final s in streams) {
      final m = s as Map<String, dynamic>;
      final codecType = m['codec_type'] as String?;
      if (codecType == 'video') {
        hasVideoStream = true;
        continue;
      }
      if (duration == Duration.zero && m['duration'] != null) {
        duration = Duration(milliseconds: (double.parse('${m['duration']}') * 1000).round());
      }
      bitrate = int.tryParse('${m['bit_rate'] ?? ''}');
      sampleRate = int.tryParse('${m['sample_rate'] ?? ''}');
      channels = (m['channels'] as num?)?.toInt();
      final name = m['codec_name'] as String?;
      if (name != null) formatName = name.toLowerCase();
    }
    if (format['duration'] != null && duration == Duration.zero) {
      duration = Duration(milliseconds: (double.parse('${format['duration']}') * 1000).round());
    }
    if (format['bit_rate'] != null && bitrate == null) {
      bitrate = int.tryParse('${format['bit_rate']}');
    }
    final declaredFormat = format['format_name'] as String?;
    if (declaredFormat != null && formatName == 'unknown') {
      formatName = declaredFormat.split(',').first.trim().toLowerCase();
    }
    final artwork = _artworkFromTags(tags) ?? (hasVideoStream ? _coverArtForFile(path) : null);
    return _build(meta: tags, duration: duration, path: path, bitrate: bitrate, sampleRate: sampleRate, channels: channels, formatName: formatName, artwork: artwork);
  }

  ExtractedMetadata _build({
    required Map<String, dynamic> meta,
    required Duration duration,
    required String path,
    int? bitrate,
    int? sampleRate,
    int? channels,
    String? formatName,
    (List<int>, String)? artwork,
  }) {
    String? str(String key) {
      final v = meta[key];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    int? num(String key) {
      final v = meta[key];
      if (v == null) return null;
      return int.tryParse(v.toString().trim().split(RegExp(r'[^0-9]')).first);
    }

    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    return ExtractedMetadata(
      durationMs: duration.inMilliseconds,
      format: formatName ?? ext,
      title: str('title'),
      artist: str('artist'),
      album: str('album'),
      albumArtist: str('albumartist') ?? str('albumArtist') ?? str('artist'),
      genre: str('genre'),
      releaseYear: num('date') ?? num('year'),
      trackNumber: num('track'),
      discNumber: num('disc'),
      bitrate: bitrate,
      sampleRate: sampleRate,
      channels: channels,
      artworkBytes: artwork?.$1,
      artworkMime: artwork?.$2,
    );
  }

  /// MP3 ID3 APIC tag (base64 in ffprobe output).
  (List<int>, String)? _artworkFromTags(Map<String, dynamic> tags) {
    for (final key in tags.keys) {
      if (key.toLowerCase().startsWith('apic:')) {
        try {
          final bytes = base64Decode(tags[key] as String);
          return (bytes, _guessImageMime(bytes) ?? 'image/jpeg');
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  /// Minimal embedded cover extraction for FLAC (front cover block).
  (List<int>, String)? _coverArtForFile(String path) {
    try {
      final data = File(path).readAsBytesSync();
      if (data.length < 4 ||
          data[0] != 0x66 || data[1] != 0x4C || data[2] != 0x41 || data[3] != 0x43) {
        return null;
      }
      var offset = 4;
      while (offset + 4 <= data.length) {
        final size = _readU32(data, offset);
        final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
        offset += 8;
        if (type == 'PICT') {
          // 1-byte reserved, 3-byte mime length, mime, description\0, 2 colors, W, H, bpp, len
          var p = offset;
          final mimeLen = data[p + 4];
          final mime = String.fromCharCodes(data.sublist(p + 5, p + 5 + mimeLen));
          p += 5 + mimeLen;
          while (p < data.length && data[p] != 0) {
            p++;
          }
          p += 1 + 2; // description terminator + color description
          final len = _readU32(data, p + 8);
          final start = p + 12;
          if (start + len > data.length) return null;
          return (data.sublist(start, start + len), mime.isEmpty ? 'image/jpeg' : 'image/$mime');
        }
        offset += size;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  int _readU32(List<int> data, int offset) =>
      (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];

  /// just_audio-only fallback: duration plus a title derived from the name.
  Future<ExtractedMetadata> _extractFallback(String path) async {
    final player = AudioPlayer();
    Duration duration = Duration.zero;
    try {
      await player.setAudioSource(AudioSource.file(path));
      await player.processingStateStream
          .firstWhere((s) => s == ProcessingState.ready || s == ProcessingState.idle)
          .timeout(const Duration(seconds: 10), onTimeout: () => ProcessingState.idle);
      duration = player.duration ?? Duration.zero;
    } catch (e) {
      AppLogger.warning('Fallback decode failed for $path: $e', tag: 'metadata');
    } finally {
      await player.dispose();
    }
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    return ExtractedMetadata(durationMs: duration.inMilliseconds, format: ext, title: title);
  }

  /// Streaming SHA-256 of a file, chunked to keep memory flat.
  Future<String> fileHash(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileOperationException('File not found: $path');
    }
    final completer = Completer<Digest>();
    final chunked = sha256.startChunkedConversion(_DigestSink(completer));
    final raf = await file.open();
    try {
      while (true) {
        final chunk = await raf.read(256 * 1024);
        if (chunk.isEmpty) break;
        chunked.add(chunk);
      }
    } finally {
      chunked.close();
      await raf.close();
    }
    return (await completer.future).toString();
  }

  String? _guessImageMime(List<int> bytes) {
    if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length > 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }
}
