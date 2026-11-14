import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';
import 'package:music_player/features/downloader/domain/youtube_resolver.dart';

/// Persistent download queue and history.
///
/// The download engine executes queued tasks; this screen provides queue
/// management, live progress, pause, retry and cancellation.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  /// Returns the first line of [raw] that looks like a plain single-line
  /// http(s) URL, or the empty string if none does. Multi-line pastes
  /// (URL + JSON metadata, trailing lines, etc.) are common; Dart's Uri
  /// parser would otherwise percent-encode the newlines into one bogus URL.
  static String firstUrlLine(String raw) => raw
      .split(RegExp(r'[\r\n]+'))
      .map((s) => s.trim())
      .firstWhere(
          (s) => RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(s),
          orElse: () => '');

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  bool _adding = false;
  bool _searching = false;
  List<YtDlpEntry> _searchResults = const [];
  List<DownloadTask> _active = const [];
  List<DownloadTask> _queued = const [];
  List<DownloadTask> _paused = const [];
  List<DownloadTask> _history = const [];
  StreamSubscription<List<DownloadTask>>? _activeSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Live updates: the engine persists progress to the database, and this
    // stream is re-emitted on every change.
    _activeSub = ref
        .read(appDepsProvider)
        .downloader
        .active
        .listen((tasks) {
      if (mounted) setState(() => _active = tasks);
    });
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _urlController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Searches YouTube (via yt-dlp's `ytsearch` extractor) and shows the
  /// results; tapping one queues it for download.
  Future<void> _searchYouTube() async {
    final q = _searchController.text.trim();
    if (q.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchResults = const [];
    });
    try {
      final results =
          await ref.read(appDepsProvider).downloader.searchYouTube(q);
      if (!mounted) return;
      setState(() => _searchResults = results);
      if (results.isEmpty) _showSnack('No YouTube results found.');
    } catch (e) {
      _showSnack('YouTube search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _queueSearchResult(YtDlpEntry entry) async {
    try {
      final summary =
          await ref.read(appDepsProvider).downloader.queueYouTube(entry.watchUrl);
      _showSnack(summary.queued == 1
          ? '“${entry.title}” queued for download'
          : 'Queued ${summary.queued} tracks');
      await _load();
    } catch (e) {
      _showSnack('Could not queue: $e');
    }
  }

  /// Adds a direct media URL to the download queue.
  ///
  /// The title is derived from the URL's file name; a more meaningful
  /// title/artist/album can still be corrected after the file is imported
  /// (metadata extraction fills what the file itself declares).
  Future<void> _add() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty || _adding) return;
    // People sometimes paste extra text along with the link (metadata,
    // JSON, trailing lines). Dart's Uri parser silently percent-encodes
    // newlines, so a multi-line paste would otherwise become one bogus
    // URL. Pick the first line that actually looks like a plain link.
    final url = DownloadsScreen.firstUrlLine(raw);
    if (url.isEmpty) {
      _showSnack('Paste a single link starting with http:// or https:// '
          '(no extra text).');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _showSnack('Enter a valid http(s) URL.');
      return;
    }
    setState(() => _adding = true);
    try {
      final engine = ref.read(appDepsProvider).downloader;
      final path = uri.path.toLowerCase();
      if (YouTubeResolver.isYouTubeUrl(uri.toString())) {
        final summary = await engine.queueYouTube(uri.toString());
        _showSnack(summary.queued == 1
            ? 'YouTube track queued'
            : summary.ignored > 0
                ? 'Queued ${summary.queued} tracks from YouTube playlist '
                    '(${summary.ignored} skipped)'
                : 'Queued ${summary.queued} tracks from YouTube playlist');
      } else if (path.endsWith('.m3u') || path.endsWith('.m3u8')) {
        final summary = await engine.queuePlaylist(uri.toString());
        _showSnack(summary.ignored > 0
            ? 'Queued ${summary.queued} tracks from playlist '
                '(${summary.ignored} skipped)'
            : 'Queued ${summary.queued} tracks from playlist');
      } else {
        await engine.queue(url: uri.toString(), title: _titleFromUri(uri));
      }
      _urlController.clear();
      await _load();
    } catch (e) {
      final detail = e is FormatException
          ? 'that link looks malformed — paste a plain http(s) URL only'
          : '$e';
      _showSnack('Could not queue: $detail');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Derives a display title from a URL: last path segment without extension,
  /// with underscores/dashes turned into spaces.
  static String _titleFromUri(Uri uri) {
    final segment = p.basename(uri.path).replaceAll(RegExp(r'[^\w\s-]'), '');
    final name = p.basenameWithoutExtension(segment);
    if (name.isEmpty || name == '.') return 'Download';
    return name.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    final results = await Future.wait([
      deps.downloads.queued(limit: 100),
      deps.downloads.paused(),
      deps.downloads.history(),
    ]);
    if (!mounted) return;
    setState(() {
      _queued = results[0];
      _paused = results[1];
      _history = results[2];
    });
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(appDepsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          _addForm(),
          _addFormHint(),
          _searchSection(),
          Expanded(
            child: _active.isEmpty &&
                    _queued.isEmpty &&
                    _paused.isEmpty &&
                    _history.isEmpty
                ? const Center(
                    child: Text(
                        'No download tasks yet.\nAdd media to the download queue to make it available offline.'),
                  )
                : ListView(
                    children: [
                      if (_active.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('In progress',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final task in _active)
                    _taskTile(task, deps, inFlight: true),
                ],
                if (_queued.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Queue',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final task in _queued)
                    _taskTile(task, deps, cancellable: true),
                ],
                if (_paused.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Paused',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final task in _paused)
                    _taskTile(task, deps, cancellable: true),
                ],
                      if (_history.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('History',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        for (final task in _history) _taskTile(task, deps),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _addForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Track URL, playlist (.m3u8), or YouTube link',
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: _adding
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            label: const Text('Queue'),
            onPressed: _adding ? null : _add,
          ),
        ],
      ),
    );
  }

  /// YouTube search: type a query, tap a result to queue it.
  Widget _searchSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search YouTube',
                    hintText: 'Artist, song, or channel…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _searchYouTube(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                icon: _searching
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('Search'),
                onPressed: _searching ? null : _searchYouTube,
              ),
            ],
          ),
          if (_searchResults.isNotEmpty)
            for (final e in _searchResults)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _SearchThumb(url: e.thumbnail),
                ),
                title: Text(e.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(e.channel ?? 'YouTube',
                    style: const TextStyle(fontSize: 11)),
                onTap: () => _queueSearchResult(e),
                trailing: IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Queue for download',
                  onPressed: () => _queueSearchResult(e),
                ),
              ),
          if (_searchResults.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                  'Tap a result (or the download icon) to queue it.',
                  style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  /// Hint below the form explaining what URLs are accepted.
  Widget _addFormHint() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
            'Paste a track URL, an M3U/M3U8 playlist, or a YouTube video/playlist link. ')
            // YouTube links queue as watch URLs and are resolved at download time.
      ),
    );
  }

  Widget _taskTile(DownloadTask task, dynamic deps,
      {bool cancellable = false, bool inFlight = false}) {
    final status = task.status;
    final engine = deps.downloader;
    final isFailed = status == DownloadTaskStatus.failed ||
        status == DownloadTaskStatus.cancelled ||
        status == DownloadTaskStatus.paused;
    final bytes = task.bytesDone;
    final speed = task.speedBps;
    return ListTile(
      title: Text(task.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${task.artist} · ${task.album}'),
          if (inFlight)
            LinearProgressIndicator(
                value: task.progress == 0 ? null : task.progress),
          if (bytes > 0)
            Text(
                '${_fmtBytes(bytes)}${status == DownloadTaskStatus.downloading && speed > 0 ? ' · ${_fmtBytes(speed)}/s' : ''}',
                style: const TextStyle(fontSize: 11)),
          if (task.error != null)
            Text(task.error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status.name.toUpperCase()),
          if (isFailed)
            IconButton(
              icon: const Icon(Icons.replay),
              tooltip: 'Retry',
              onPressed: () async {
                await engine.retry(task.id);
                await _load();
              },
            ),
          if (inFlight)
            IconButton(
              icon: const Icon(Icons.pause),
              tooltip: 'Pause',
              onPressed: () async {
                await engine.pause(task.id);
                await _load();
              },
            ),
          if (cancellable || inFlight)
            IconButton(
              icon: const Icon(Icons.cancel),
              tooltip: 'Cancel',
              onPressed: () async {
                await engine.cancel(task.id);
                await _load();
              },
            ),
        ],
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Remote thumbnail for search results, with a safe placeholder.
class _SearchThumb extends StatelessWidget {
  const _SearchThumb({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.music_note, size: 24));
    }
    return Image.network(
      url!,
      width: 44,
      height: 44,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.music_note, size: 24),
    );
  }
}
