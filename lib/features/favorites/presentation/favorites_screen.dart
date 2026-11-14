import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/empty_view.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  List<Track> _tracks = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tracks = await ref.read(appDepsProvider).tracks.favorites();
    if (mounted) setState(() => _tracks = tracks);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: _tracks.isEmpty
          ? const EmptyView(
              icon: Icons.favorite_outline,
              title: 'No favorites yet',
              message: 'Tap the heart on any track to save it here.',
            )
          : ListView.builder(
              itemCount: _tracks.length,
              itemBuilder: (_, i) {
                final track = _tracks[i];
                return TrackListTile(
                  track: track,
                  onTap: () => ref.read(playerProvider).playQueue(_tracks, startIndex: i),
                  trailing: IconButton(
                    icon: const Icon(Icons.favorite),
                    onPressed: () async {
                      await ref.read(appDepsProvider).tracks.toggleFavorite(track.id);
                      await _load();
                    },
                  ),
                );
              },
            ),
    );
  }
}
