import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/library/domain/duplicate_finder.dart';
import 'package:music_player/shared/widgets/empty_view.dart';

/// Popped back to the library screen so it can refresh its list.
enum DuplicateCleanupResult { none, deleted }

/// "Find and delete the same song so there is only one copy": shows every
/// group of duplicate tracks and lets the user pick which copy to keep
/// (most-played copy preselected) before deleting the extras along with
/// their audio files.
class DuplicateCleanupPage extends ConsumerStatefulWidget {
  const DuplicateCleanupPage({super.key});

  @override
  ConsumerState<DuplicateCleanupPage> createState() =>
      _DuplicateCleanupPageState();
}

class _DuplicateCleanupPageState extends ConsumerState<DuplicateCleanupPage> {
  List<DuplicateGroup> _groups = const [];
  bool _loading = true;
  bool _busy = false;
  bool _deletedAnything = false;

  /// group titleKey -> id of the track the user chose to keep.
  final Map<String, String> _keep = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tracks = await ref.read(appDepsProvider).tracks.allTracks();
      final groups = findDuplicates(tracks);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        // Preselect the recommended keeper unless the user already chose.
        for (final g in groups) {
          if (!_keep.containsKey(g.key)) _keep[g.key] = g.keeper.id;
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  int get _extraCount => _groups.fold(0, (n, g) => n + g.extras.length);

  Future<void> _confirmAndDelete(List<Track> victims) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete duplicates'),
        content: Text(
            victims.length == 1
                ? 'Delete 1 duplicate track and its audio file?'
                : 'Delete ${victims.length} duplicate tracks and their audio files?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _deletedAnything = true;
    });
    final library = ref.read(appDepsProvider).tracks;
    for (final track in victims) {
      try {
        await library.removeTrack(track.id, deleteFile: true);
      } catch (_) {
        // Keep going; report at the end if anything remains.
      }
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    final remaining = _extraCount;
    if (remaining > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$remaining duplicate(s) could not be deleted')),
      );
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Duplicates removed')));
    }
  }

  /// Deletes every extra copy in [group] (keeping [_keep] or the default).
  Future<void> _deleteGroup(DuplicateGroup group) async {
    final keepId = _keep[group.key] ?? group.keeper.id;
    final victims = group.tracks.where((t) => t.id != keepId).toList();
    if (victims.isEmpty) return;
    await _confirmAndDelete(victims);
  }

  /// Deletes every extra copy in every group.
  Future<void> _deleteAll() async {
    if (_extraCount == 0) return;
    final victims = <Track>[];
    for (final group in _groups) {
      final keepId = _keep[group.key] ?? group.keeper.id;
      victims.addAll(group.tracks.where((t) => t.id != keepId));
    }
    await _confirmAndDelete(victims);
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _date(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicate cleanup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Scan again',
            onPressed: _loading || _busy ? null : _load,
          ),
        ],
        leading: _deletedAnything
            ? BackButton(
                onPressed: () =>
                    Navigator.of(context).pop(DuplicateCleanupResult.deleted),
              )
            : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? const EmptyView(
                  icon: Icons.fact_check,
                  title: 'No duplicates found',
                  message:
                      'Every song in your library appears exactly once.',
                )
              : Column(
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_groups.length} group(s) with $_extraCount extra copy(ies)',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          FilledButton.tonal(
                            onPressed: _busy ? null : _deleteAll,
                            child: Text(
                                'Delete all $_extraCount duplicates'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: _groups.length,
                        itemBuilder: (_, i) =>
                            _groupCard(_groups[i]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _groupCard(DuplicateGroup group) {
    final keepId = _keep[group.key] ?? group.keeper.id;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < group.tracks.length; i++)
            RadioListTile<String>(
              title: Text(group.tracks[i].title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${group.tracks[i].artist} · '
                '${_fmt(Duration(milliseconds: group.tracks[i].durationMs))} · '
                '${group.tracks[i].sourceType} · added ${_date(group.tracks[i].dateAdded)}'
                '${group.tracks[i].playCount > 0 ? ' · played ${group.tracks[i].playCount}x' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              value: group.tracks[i].id,
              groupValue: keepId,
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) setState(() => _keep[group.key] = v);
                    },
              secondary: group.tracks[i].id == keepId
                  ? const Icon(Icons.star, color: Colors.orange)
                  : null,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _busy || group.extras.isEmpty ? null : () => _deleteGroup(group),
                child: Text(group.extras.length == 1
                    ? 'Delete 1 duplicate'
                    : 'Delete ${group.extras.length} duplicates'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

