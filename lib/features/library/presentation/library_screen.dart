import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// All-songs view with sorting and drag-drop/file-picker import.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const int _pageSize = 200;

  List<Track> _tracks = const [];
  String _order = 'date_added';
  bool _loading = false;
  bool _loadingMore = false;
  bool _exhausted = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    setState(() {
      _loading = true;
      _exhausted = false;
    });
    try {
      final tracks =
          await deps.tracks.tracks(orderBy: _order, limit: _pageSize);
      if (mounted) setState(() => _tracks = tracks);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Appends the next page while the current page filled the list view.
  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    setState(() => _loadingMore = true);
    try {
      final next = await ref
          .read(appDepsProvider)
          .tracks
          .tracks(orderBy: _order, limit: _pageSize, offset: _tracks.length);
      if (mounted && next.isNotEmpty) {
        setState(() {
          _tracks = [..._tracks, ...next];
          _exhausted = next.length < _pageSize;
        });
      } else if (mounted) {
        setState(() => _exhausted = true);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _import() async {
    final deps = ref.read(appDepsProvider);
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return;
      final paths = result.files.map((f) => f.path).where((p) => p != null).cast<String>().toList();
      final importResult = await deps.importer.importPaths(paths,
          onProgress: (done, total, current) => debugPrint('Importing $done/$total'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported ${importResult.added} track(s); '
              '${importResult.duplicates} duplicate(s); ${importResult.errors} error(s)'),
        ));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _order,
              items: const [
                DropdownMenuItem(value: 'date_added', child: Text('Recently added')),
                DropdownMenuItem(value: 'title', child: Text('Title')),
                DropdownMenuItem(value: 'artist', child: Text('Artist')),
                DropdownMenuItem(value: 'album', child: Text('Album')),
                DropdownMenuItem(value: 'play_count', child: Text('Most played')),
                DropdownMenuItem(value: 'duration', child: Text('Duration')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _order = v);
                _load();
              },
            ),
          ),
          IconButton(
            icon: _importing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_upload_outlined),
            tooltip: 'Import music',
            onPressed: _importing ? null : _import,
          ),
        ],
      ),
      body: _loading && _tracks.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _tracks.isEmpty
              ? const Center(child: Text('No music yet. Import files to get started.'))
              : ListView.builder(
                  // Extra item is a spinner footer shown while a page loads.
                  itemCount: _tracks.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == _tracks.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    // Trigger the next page as the user scrolls near the end.
                    if (i >= _tracks.length - 10 && !_exhausted && !_loadingMore) {
                      _loadMore();
                    }
                    final track = _tracks[i];
                    return TrackListTile(
                      track: track,
                      onTap: () => ref.read(playerProvider).playQueue(_tracks, startIndex: i),
                      trailing: IconButton(
                        icon: const Icon(Icons.favorite),
                        onPressed: () => ref.read(appDepsProvider).tracks.toggleFavorite(track.id),
                      ),
                      onRemove: (deleteFile) async {
                        await ref
                            .read(appDepsProvider)
                            .tracks
                            .removeTrack(track.id, deleteFile: deleteFile);
                        await _load();
                      },
                    );
                  },
                ),
    );
  }
}
