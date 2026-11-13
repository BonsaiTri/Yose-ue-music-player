import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';

/// Persistent download queue and history.
///
/// The download engine executes queued tasks; this screen provides queue
/// management, live progress, pause, retry and cancellation.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _adding = false;
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
    super.dispose();
  }

  /// Adds a direct media URL to the download queue.
  ///
  /// The title is derived from the URL's file name; a more meaningful
  /// title/artist/album can still be corrected after the file is imported
  /// (metadata extraction fills what the file itself declares).
  Future<void> _add() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _adding) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _showSnack('Enter a valid http(s) URL.');
      return;
    }
    setState(() => _adding = true);
    try {
      await ref
          .read(appDepsProvider)
          .downloader
          .queue(url: uri.toString(), title: _titleFromUri(uri));
      _urlController.clear();
      await _load();
    } catch (e) {
      _showSnack('Could not queue: $e');
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
                labelText: 'Media URL (http/https)',
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
