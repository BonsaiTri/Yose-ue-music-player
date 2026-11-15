import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/playlists/presentation/playlist_detail_page.dart';
import 'package:music_player/shared/widgets/empty_view.dart';

/// Playlists index: create, open, play, rename, delete.
class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  List<Playlist> _playlists = const [];
  final Map<String, int> _counts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    final playlists = await deps.playlists.all();
    final counts = <String, int>{};
    for (final pl in playlists) {
      counts[pl.id] = await deps.playlists.trackCount(pl.id);
    }
    if (mounted) {
      setState(() {
        _playlists = playlists;
        _counts
          ..clear()
          ..addAll(counts);
      });
    }
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(appDepsProvider).playlists.create(name);
    await _load();
  }

  /// Long-press menu: play, rename, delete.
  Future<void> _manage(Playlist playlist) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('“${playlist.name}”',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Play all'),
              onTap: () => Navigator.pop(ctx, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.shuffle),
              title: const Text('Shuffle play'),
              onTap: () => Navigator.pop(ctx, 'shuffle'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete playlist',
                  style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == 'play') {
      final tracks = await ref.read(appDepsProvider).playlists.tracks(playlist.id);
      if (tracks.isNotEmpty) {
        ref.read(playerProvider).playQueue(tracks);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('This playlist is empty')));
      }
    } else if (action == 'shuffle') {
      final tracks = await ref.read(appDepsProvider).playlists.tracks(playlist.id);
      if (tracks.isNotEmpty) {
        final shuffled = List.of(tracks)..shuffle(Random());
        ref.read(playerProvider).playQueue(shuffled);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('This playlist is empty')));
      }
    } else if (action == 'rename') {
      await _rename(playlist);
    } else if (action == 'delete') {
      await _confirmDelete(playlist);
    }
  }

  Future<void> _rename(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == playlist.name) return;
    await ref.read(appDepsProvider).playlists.rename(playlist.id, name);
    await _load();
  }

  Future<void> _confirmDelete(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${playlist.name}”?'),
        content: const Text(
            'The playlist is removed. Your music stays in the library.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(appDepsProvider).playlists.delete(playlist.id);
    await _load();
  }

  Future<void> _open(Playlist playlist) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailPage(playlist: playlist),
    ));
    // The playlist may have changed (renamed, reordered, tracks added).
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton:
          FloatingActionButton(onPressed: _create, child: const Icon(Icons.add)),
      body: _playlists.isEmpty
          ? const EmptyView(
              icon: Icons.playlist_play_outlined,
              title: 'No playlists yet',
              message:
                  'Tap + to create a playlist and organize your favorite tracks.',
            )
          : ListView.builder(
              itemCount: _playlists.length,
              itemBuilder: (_, i) {
                final playlist = _playlists[i];
                final count = _counts[playlist.id] ?? 0;
                return ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(playlist.name),
                  subtitle: Text(
                      count == 1 ? '1 track' : '$count tracks'),
                  onTap: () => _open(playlist),
                  onLongPress: () => _manage(playlist),
                );
              },
            ),
    );
  }
}
