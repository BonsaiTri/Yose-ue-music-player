import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/empty_view.dart';

/// Genres list; tapping a genre plays its catalog in alphabetical order.
class GenresScreen extends ConsumerStatefulWidget {
  const GenresScreen({super.key});

  @override
  ConsumerState<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends ConsumerState<GenresScreen> {
  List<Genre> _genres = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final genres = await ref.read(appDepsProvider).genres.all();
    if (mounted) setState(() => _genres = genres);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Genres')),
      body: _genres.isEmpty
          ? const EmptyView(
              icon: Icons.local_offer_outlined,
              title: 'No genres yet',
              message: 'Genres appear here once you import music with tags.',
            )
          : ListView.builder(
              itemCount: _genres.length,
              itemBuilder: (_, i) {
                final genre = _genres[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.local_offer_outlined)),
                  title: Text(genre.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final tracks =
                        await ref.read(appDepsProvider).tracks.byGenre(genre.id);
                    if (tracks.isEmpty || !mounted) return;
                    ref.read(playerProvider).playQueue(tracks);
                  },
                );
              },
            ),
    );
  }
}
