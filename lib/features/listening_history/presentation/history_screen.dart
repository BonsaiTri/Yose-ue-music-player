import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/shared/widgets/empty_view.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// Listening history: recently played tracks and counts, with clearing.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<dynamic> _recent = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final recent = await ref.read(appDepsProvider).history.recent();
    if (mounted) setState(() => _recent = recent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear history',
            onPressed: () async {
              await ref.read(appDepsProvider).history.clear();
              await _load();
            },
          ),
        ],
      ),
      body: _recent.isEmpty
          ? const EmptyView(
              icon: Icons.history_outlined,
              title: 'Nothing played yet',
              message: 'Tracks you play will show up here.',
            )
          : ListView.builder(
              itemCount: _recent.length,
              itemBuilder: (_, i) {
                final entry = _recent[i];
                final track = entry.$1;
                final playedAt = entry.$2;
                return TrackListTile(
                  track: track,
                  onTap: () => ref.read(playerProvider).playTrack(track),
                  trailing: Text(
                    '${playedAt.year}-${playedAt.month.toString().padLeft(2, '0')}-${playedAt.day.toString().padLeft(2, '0')} '
                    '${playedAt.hour.toString().padLeft(2, '0')}:${playedAt.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                );
              },
            ),
    );
  }
}
