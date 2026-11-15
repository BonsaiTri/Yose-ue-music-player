import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/features/downloader/domain/download_engine.dart';
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

class _DownloadsScreenState extends ConsumerState<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  late final TabController _tabController;
  final GlobalKey _linkListAnchor = GlobalKey();
  final GlobalKey _ytListAnchor = GlobalKey();
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
    _tabController = TabController(vsync: this, length: 2);
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
    _tabController.dispose();
    super.dispose();
  }

  /// After a successful queue, scroll the current tab's list so the
  /// queue/history is visible again.
  void _returnToQueue() {
    if (!mounted) return;
    final anchor = _tabController.index == 0 ? _linkListAnchor : _ytListAnchor;
    final ctx = anchor.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.0, duration: const Duration(milliseconds: 300));
  }

  /// Searches YouTube (via yt-dlp's `ytsearch` extractor) and shows the
  /// results; tapping one queues it for download.
  Future<void> _searchYouTube() async {
    final q = _searchController.text.trim();
    if (q.isEmpty || _searching) return;
    AppLogger.info('YT search tapped: "$q"', tag: 'download');
    setState(() {
      _searching = true;
      _searchResults = const [];
    });
    try {
      final results =
          await ref.read(appDepsProvider).downloader.searchYouTube(q);
      if (!mounted) return;
      AppLogger.info('YT search done: ${results.length} results', tag: 'download');
      setState(() => _searchResults = results);
      if (results.isEmpty) _showSnack('No YouTube results found.');
    } catch (e) {
      AppLogger.error('YT search failed: $e', tag: 'download');
      _showSnack('YouTube search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Fixes every failed download in one action: transient failures are
  /// re-queued, and dead videos are replaced by their top available
  /// version on YouTube.
  Future<void> _rescueFailed() async {
    setState(() => _adding = true);
    try {
      final result = await ref.read(appDepsProvider).downloader.rescueFailed();
      await _load();
      final parts = <String>[];
      if (result.replaced > 0) {
        parts.add('queued ${result.replaced} available version' +
            (result.replaced == 1 ? '' : 's'));
      }
      if (result.retried > 0) {
        parts.add('retried ${result.retried}');
      }
      if (result.unresolved > 0) {
        parts.add('${result.unresolved} had no available version');
      }
      _showSnack(
          parts.isEmpty ? 'No failed downloads to fix' : parts.join(' — '));
    } catch (e) {
      _showSnack('Could not process failed downloads: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Re-queues every failed download in one action. Permanently dead
  /// videos (removed or Premium-only sources) are skipped and reported.
  Future<void> _retryAllFailed() async {
    setState(() => _adding = true);
    try {
      final result =
          await ref.read(appDepsProvider).downloader.retryFailed();
      await _load();
      final parts = <String>[];
      if (result.retried > 0) {
        parts.add('Retried ${result.retried} failed download' +
            (result.retried == 1 ? '' : 's'));
      }
      if (result.skipped > 0) {
        parts.add('skipped ${result.skipped} dead video' +
            (result.skipped == 1 ? '' : 's') +
            ' (source removed or Premium-only)');
      }
      _showSnack(parts.isEmpty ? 'No failed downloads to retry' : parts.join(' — '));
    } catch (e) {
      _showSnack('Could not retry failed downloads: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Asks for confirmation, then deletes all finished download records.
  /// Music and files in the library are not affected.
  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text(
            'Removes all finished download records. Your music and the '
            'downloaded files stay in the library.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final removed =
          await ref.read(appDepsProvider).downloads.clearHistory();
      await _load();
      _showSnack(removed > 0
          ? 'Cleared $removed history records'
          : 'History is already empty');
    } catch (e) {
      _showSnack('Could not clear history: $e');
    }
  }

  /// Opens a sheet that searches YouTube for other available uploads of a
  /// song whose original video is dead.
  Future<void> _suggestVersions(DownloadTask task) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SuggestVersionsSheet(task: task),
    );
    if (result == true && mounted) await _load();
  }

  Future<void> _queueSearchResult(YtDlpEntry entry) async {
    AppLogger.info('YT search result tapped: "${entry.title}"', tag: 'download');
    try {
      final summary =
          await ref.read(appDepsProvider).downloader.queueYouTube(entry.watchUrl);
      _showSnack(summary.queued == 1
          ? '“${entry.title}” queued for download'
          : 'Queued ${summary.queued} tracks');
      await _load();
      _returnToQueue();
    } on AlreadyDownloadedError catch (e) {
      _showSnack(e.message);
    } on AlreadyInQueueError catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not queue: $e');
    }
  }

  /// "Queued N tracks" plus the counts of entries that were already in the
  /// library or could not be queued.
  static String _queueSummaryText(PlaylistQueueSummary summary,
      {required String source, required String single}) {
    final parts = <String>[
      summary.queued == 1
          ? single
          : 'Queued ${summary.queued} tracks from $source',
    ];
    if (summary.alreadyDownloaded > 0) {
      parts.add('${summary.alreadyDownloaded} already downloaded');
    }
    if (summary.ignored > 0) {
      parts.add('${summary.ignored} skipped');
    }
    return parts.join(' · ');
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
        _showSnack(_queueSummaryText(
            summary, source: 'YouTube playlist', single: 'YouTube track queued'));
      } else if (path.endsWith('.m3u') || path.endsWith('.m3u8')) {
        final summary = await engine.queuePlaylist(uri.toString());
        _showSnack(_queueSummaryText(
            summary, source: 'playlist', single: 'Track queued'));
      } else {
        await engine.queue(url: uri.toString(), title: _titleFromUri(uri));
      }
      _urlController.clear();
      await _load();
      _returnToQueue();
    } on AlreadyDownloadedError catch (e) {
      _showSnack(e.message);
    } on AlreadyInQueueError catch (e) {
      _showSnack(e.message);
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
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.link), text: 'Link'),
              Tab(icon: Icon(Icons.search), text: 'YouTube'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_linkTab(deps), _youtubeTab(deps)],
            ),
          ),
        ],
      ),
    );
  }

  /// "Link" tab: paste a track/playlist/YouTube URL and queue it.
  Widget _linkTab(dynamic deps) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _addForm(),
        _addFormHint(),
        SizedBox(key: _linkListAnchor),
        ..._taskList(deps),
      ],
    );
  }

  /// "YouTube" tab: search and tap a result to queue it.
  Widget _youtubeTab(dynamic deps) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _searchForm(),
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
        SizedBox(key: _ytListAnchor),
        ..._taskList(deps),
      ],
    );
  }

  /// The shared in-progress / queue / paused / history sections, or the
  /// empty-state message.
  List<Widget> _taskList(dynamic deps) {
    if (_active.isEmpty &&
        _queued.isEmpty &&
        _paused.isEmpty &&
        _history.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No download tasks yet.\nAdd media to the download queue to make it available offline.'),
        ),
      ];
    }
    return [
      if (_active.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('In progress',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final task in _active) _taskTile(task, deps, inFlight: true),
      ],
      if (_queued.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Queue',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final task in _queued) _taskTile(task, deps, cancellable: true),
      ],
      if (_paused.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Paused',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final task in _paused) _taskTile(task, deps, cancellable: true),
      ],
      if (_history.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('History',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (_history
                  .any((t) => t.status == DownloadTaskStatus.failed))
                IconButton(
                  icon: const Icon(Icons.replay),
                  tooltip: 'Retry all failed downloads',
                  onPressed: _retryAllFailed,
                ),
              if (_history.any((t) =>
                  t.status == DownloadTaskStatus.failed &&
                  DownloadEngine.isPermanentFailure(t.error)))
                IconButton(
                  icon: const Icon(Icons.auto_fix_high),
                  tooltip: 'Download an available version of every failed song',
                  onPressed: _rescueFailed,
                ),
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Clear history',
                onPressed: _confirmClearHistory,
              ),
            ],
          ),
        ),
        for (final task in _history) _taskTile(task, deps),
      ],
    ];
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

  /// YouTube search input row (results are rendered in the tab list).
  Widget _searchForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
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
          if (!inFlight &&
              status == DownloadTaskStatus.queued)
            const LinearProgressIndicator(),
          if (inFlight)
            Text(
                '${task.progress == 0 ? '' : '${(task.progress * 100).round()}% · '}${bytes > 0 ? _fmtBytes(bytes) : 'preparing'}${status == DownloadTaskStatus.downloading && speed > 0 ? ' · ${_fmtBytes(speed)}/s' : ''}',
                style: const TextStyle(fontSize: 11)),
          if (task.error != null)
            Text(
              DownloadEngine.isPermanentFailure(task.error)
                  ? '${task.error!} · dead source, will not be retried'
                  : task.error!,
              style: const TextStyle(color: Colors.red, fontSize: 11),
            ),
          if (isFailed &&
              DownloadEngine.isPermanentFailure(task.error) &&
              YouTubeResolver.isYouTubeUrl(task.url))
            TextButton.icon(
              onPressed: () => _suggestVersions(task),
              icon: const Icon(Icons.recommend, size: 16),
              label: const Text('Suggest an available version',
                  style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
          if (!inFlight &&
              status == DownloadTaskStatus.queued &&
              bytes > 0)
            Text(_fmtBytes(bytes), style: const TextStyle(fontSize: 11)),
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

/// Bottom sheet offering other available YouTube uploads for a song whose
/// original video is dead (removed, private, or Premium-only).
class _SuggestVersionsSheet extends ConsumerStatefulWidget {
  const _SuggestVersionsSheet({required this.task});

  final DownloadTask task;

  @override
  ConsumerState<_SuggestVersionsSheet> createState() =>
      _SuggestVersionsSheetState();
}

class _SuggestVersionsSheetState extends ConsumerState<_SuggestVersionsSheet> {
  List<YtDlpEntry>? _entries;
  String? _error;
  bool _queuing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await ref
          .read(appDepsProvider)
          .downloader
          .suggestAlternatives(widget.task.id);
      if (!mounted) return;
      setState(() {
        if (entries == null) {
          _error = 'This source is not a YouTube video.';
        } else {
          _entries = entries;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _queue(YtDlpEntry entry) async {
    setState(() => _queuing = true);
    try {
      final summary = await ref
          .read(appDepsProvider)
          .downloader
          .queueYouTube(entry.watchUrl);
      if (!mounted) return;
      if (summary.queued == 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '“${entry.title}” is already downloaded or in the queue')));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('“${entry.title}” queued for download')));
      Navigator.of(context).pop(true);
    } on AlreadyDownloadedError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } on AlreadyInQueueError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not queue: $e')));
      }
    } finally {
      if (mounted) setState(() => _queuing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Original video is unavailable',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Other available uploads of “${widget.task.title}”',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else if (entries == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child:
                    Text('No other versions found on YouTube.'),
              )
            else
              ...entries.map(
                (e) => ListTile(
                  leading: _SearchThumb(url: e.thumbnail),
                  title: Text(e.title),
                  subtitle:
                      e.channel == null || e.channel!.isEmpty
                          ? null
                          : Text(e.channel!),
                  trailing: _queuing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download),
                  onTap: () => _queue(e),
                ),
              ),
          ],
        ),
      ),
    );
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
