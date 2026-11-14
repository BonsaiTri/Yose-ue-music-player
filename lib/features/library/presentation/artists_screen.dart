import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/empty_view.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// Artists list; tapping an artist plays their catalog in order.
class ArtistsScreen extends ConsumerStatefulWidget {
  const ArtistsScreen({super.key});

  @override
  ConsumerState<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends ConsumerState<ArtistsScreen> {
  List<Artist> _artists = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final artists = await ref.read(appDepsProvider).artists.all();
    if (mounted) setState(() => _artists = artists);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Artists')),
      body: _artists.isEmpty
          ? const EmptyView(
              icon: Icons.person_outline,
              title: 'No artists yet',
              message: 'Artists appear here once you import music.',
            )
          : ListView.builder(
              itemCount: _artists.length,
              itemBuilder: (_, i) {
                final artist = _artists[i];
                return ListTile(
                  title: Text(artist.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final tracks = await ref.read(appDepsProvider).tracks.byArtist(artist.id);
                    if (tracks.isEmpty || !mounted) return;
                    ref.read(playerProvider).playQueue(tracks);
                  },
                );
              },
            ),
    );
  }
}

/// Track list detail page (used by playlists and artist drill-downs).
class TrackListPage extends ConsumerWidget {
  const TrackListPage({super.key, required this.title, required this.tracks, this.onRemoved});

  final String title;
  final List<Track> tracks;
  final void Function(String trackId)? onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: tracks.isEmpty
          ? const Center(child: Text('Empty'))
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (_, i) => TrackListTile(
                track: tracks[i],
                onTap: () => ref.read(playerProvider).playQueue(tracks, startIndex: i),
                trailing: onRemoved == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => onRemoved!(tracks[i].id),
                      ),
              ),
            ),
    );
  }
}
