import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/empty_view.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// Sort modes available in a playlist. [SortMode.custom] follows the manual
/// order stored in the database; the others sort a copy in memory (the
/// stored order is untouched until the user re-drags).
enum SortMode { custom, title, artist, album, dateAdded, playCount }

extension on SortMode {
  String get label => switch (this) {
        SortMode.custom => 'Custom order (manual)',
        SortMode.title => 'Title (A–Z)',
        SortMode.artist => 'Artist (A–Z)',
        SortMode.album => 'Album (A–Z)',
        SortMode.dateAdded => 'Date added (newest)',
        SortMode.playCount => 'Play count (most played)',
      };
}

/// One playlist: browse, sort, drag-reorder, add, remove, play.
class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlist});

  final Playlist playlist;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  /// Tracks in stored (manual) order.
  List<Track> _tracks = const [];
  SortMode _sort = SortMode.custom;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    final tracks = await deps.playlists.tracks(widget.playlist.id);
    if (mounted) setState(() => _tracks = tracks);
  }

  /// The list to display: stored order for [SortMode.custom], otherwise an
  /// in-memory sorted copy.
  List<Track> get _displayed {
    if (_sort == SortMode.custom || _tracks.length < 2) return _tracks;
    final sorted = List<Track>.of(_tracks);
    sorted.sort((a, b) {
      switch (_sort) {
        case SortMode.title:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case SortMode.artist:
          return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case SortMode.album:
          return a.album.toLowerCase().compareTo(b.album.toLowerCase());
        case SortMode.dateAdded:
          return b.dateAdded.compareTo(a.dateAdded);
        case SortMode.playCount:
          return b.playCount.compareTo(a.playCount);
        case SortMode.custom:
          break;
      }
      return 0;
    });
    return sorted;
  }

  void _pickSort() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Sort by',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            for (final mode in SortMode.values)
              ListTile(
                title: Text(mode.label),
                leading: _sort == mode
                    ? const Icon(Icons.check)
                    : const Icon(Icons.radio_button_unchecked),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() => _sort = mode);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _removeFromPlaylist(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appDepsProvider)
          .playlists
          .removeTrack(widget.playlist.id, track.id);
      await _load();
      messenger.showSnackBar(SnackBar(
          content: Text('“${track.title}” removed from this playlist')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not remove: $e')));
    }
  }

  /// Draggable manual order (default drag handles on the right).
  Widget _reorderableList() {
    final list = _tracks;
    return ReorderableListView.builder(
      key: ValueKey('playlist-${widget.playlist.id}'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 16),
      buildDefaultDragHandles: true,
      onReorderItem: _reorder,
      itemCount: list.length,
      itemBuilder: (_, i) {
        final track = list[i];
        return TrackListTile(
          key: ValueKey(track.id),
          track: track,
          onTap: () => _playFrom(list, i),
          trailing: IconButton(
            icon: const Icon(Icons.playlist_remove),
            tooltip: 'Remove from this playlist',
            onPressed: () => _removeFromPlaylist(track),
          ),
        );
      },
    );
  }

  /// Moves the item from [oldIndex] to [newIndex] in the in-memory list and
  /// persists the new order. [newIndex] is already adjusted for the removal.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = List<Track>.of(_tracks);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _tracks = list);
    await ref
        .read(appDepsProvider)
        .playlists
        .reorder(widget.playlist.id, list.map((t) => t.id).toList());
  }

  void _playFrom(List<Track> list, int index) =>
      ref.read(playerProvider).playQueue(list, startIndex: index);

  Future<void> _pickTracks() async {
    final added = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => _PickTracksPage(
            playlist: widget.playlist,
            existingIds: _tracks.map((t) => t.id).toSet()),
      ),
    );
    if (added != null && added > 0) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loading = _loading;
    final displayed = _displayed;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          if (!loading && _tracks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_circle_fill),
              tooltip: 'Play all',
              onPressed: () => _playFrom(_tracks, 0),
            ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: _sort.label,
            onPressed: _pickSort,
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add tracks',
            onPressed: _pickTracks,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : _tracks.isEmpty
              ? Column(
                  children: [
                    const Expanded(
                      child: EmptyView(
                        icon: Icons.queue_music_outlined,
                        title: 'This playlist is empty',
                        message: 'Add tracks from your library.',
                      ),
                    )
                  ],
                )
              : _sort == SortMode.custom
                  ? _reorderableList()
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: displayed.length,
                      itemBuilder: (_, i) {
                        final track = displayed[i];
                        return TrackListTile(
                          track: track,
                          onTap: () => _playFrom(displayed, i),
                          trailing: IconButton(
                            icon: const Icon(Icons.playlist_remove),
                            tooltip: 'Remove from this playlist',
                            onPressed: () => _removeFromPlaylist(track),
                          ),
                        );
                      },
                    ),
      floatingActionButton: _tracks.isEmpty
          ? FloatingActionButton(
              tooltip: 'Add tracks',
              onPressed: _pickTracks,
              child: const Icon(Icons.playlist_add),
            )
          : null,
    );
  }
}

/// Track picker: browse the library, tick tracks, add them to a playlist.
class _PickTracksPage extends ConsumerStatefulWidget {
  const _PickTracksPage({required this.playlist, required this.existingIds});

  final Playlist playlist;
  final Set<String> existingIds;

  @override
  ConsumerState<_PickTracksPage> createState() => _PickTracksPageState();
}

class _PickTracksPageState extends ConsumerState<_PickTracksPage> {
  final TextEditingController _query = TextEditingController();
  List<Track> _all = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tracks =
        await ref.read(appDepsProvider).tracks.tracks(limit: 5000);
    if (mounted) {
      setState(() {
        _all = tracks;
        _loading = false;
      });
    }
  }

  List<Track> get _candidates {
    final q = _query.text.trim().toLowerCase();
    final out = <Track>[];
    for (final t in _all) {
      if (widget.existingIds.contains(t.id)) continue;
      if (q.isEmpty) {
        out.add(t);
      } else if (t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q) ||
          t.album.toLowerCase().contains(q)) {
        out.add(t);
      }
    }
    return out;
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      final deps = ref.read(appDepsProvider);
      await deps.playlists.addTracks(widget.playlist.id, _selected.toList());
      final count = _selected.length;
      Navigator.of(context).pop(count);
    } catch (_) {
      setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    final presentExisting =
        _all.where((t) => widget.existingIds.contains(t.id)).length;
    final remaining = _all.length - presentExisting;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add to “${widget.playlist.name}”'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty || _adding ? null : _addSelected,
            child: _adding
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child:
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : Text('Add ${_selected.isEmpty ? '' : '(${_selected.length})'}'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _query,
              decoration: const InputDecoration(
                hintText: 'Filter by title, artist, or album…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : candidates.isEmpty
                    ? EmptyView(
                        icon: Icons.queue_music,
                        title: 'Nothing to add',
                        message: remaining <= 0
                            ? 'Every track in your library is already in '
                                'this playlist.'
                            : 'No tracks match the filter.',
                      )
                    : ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (_, i) {
                          final t = candidates[i];
                          return CheckboxListTile(
                            value: _selected.contains(t.id),
                            title: Text(t.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${t.artist} · ${t.album}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(t.id);
                              } else {
                                _selected.remove(t.id);
                              }
                            }),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
