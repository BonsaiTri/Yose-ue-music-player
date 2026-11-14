import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/library/presentation/artists_screen.dart';
import 'package:music_player/shared/widgets/empty_view.dart';

class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  List<Playlist> _playlists = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final playlists = await ref.read(appDepsProvider).playlists.all();
    if (mounted) setState(() => _playlists = playlists);
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Playlist name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton: FloatingActionButton(onPressed: _create, child: const Icon(Icons.add)),
      body: _playlists.isEmpty
          ? const EmptyView(
              icon: Icons.playlist_play_outlined,
              title: 'No playlists yet',
              message: 'Tap + to create a playlist and organize your favorite tracks.',
            )
          : ListView.builder(
              itemCount: _playlists.length,
              itemBuilder: (_, i) {
                final playlist = _playlists[i];
                return ListTile(
                  title: Text(playlist.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(playlist),
                );
              },
            ),
    );
  }

  Future<void> _open(Playlist playlist) async {
    final tracks = await ref.read(appDepsProvider).playlists.tracks(playlist.id);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrackListPage(
        title: playlist.name,
        tracks: tracks,
        onRemoved: (trackId) async {
          await ref.read(appDepsProvider).playlists.removeTrack(playlist.id, trackId);
          await _load();
        },
      ),
    ));
  }
}
