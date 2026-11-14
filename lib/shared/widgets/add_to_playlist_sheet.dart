import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';

/// Shows the "add to playlist" bottom sheet for one or more tracks.
///
/// The sheet lists every playlist (with its track count), lets the user
/// create a new one, and adds the tracks to the chosen playlist — tracks
/// that are already present are skipped.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  List<String> trackIds,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => AddToPlaylistSheet(trackIds: trackIds),
  );
}

class AddToPlaylistSheet extends ConsumerStatefulWidget {
  const AddToPlaylistSheet({super.key, required this.trackIds});

  /// The track ids to add (in the given order).
  final List<String> trackIds;

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  final TextEditingController _newName = TextEditingController();
  List<Playlist> _playlists = const [];
  Set<String> _alreadyIn = {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    final playlists = await deps.playlists.all();
    // Membership check so rows that already contain every track can show a
    // check mark. Playlists are user-created, so this stays cheap.
    final member = <String>{};
    for (final pl in playlists) {
      final ids =
          (await deps.playlists.tracks(pl.id)).map((t) => t.id).toSet();
      if (ids.containsAll(widget.trackIds)) member.add(pl.id);
    }
    if (mounted) {
      setState(() {
        _playlists = playlists;
        _alreadyIn = member;
        _loading = false;
      });
    }
  }

  Future<void> _add(Playlist playlist) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final deps = ref.read(appDepsProvider);
      final before = await deps.playlists.trackCount(playlist.id);
      await deps.playlists.addTracks(playlist.id, widget.trackIds);
      final added = (await deps.playlists.trackCount(playlist.id)) - before;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
          content: Text(added > 0
              ? 'Added $added track${added == 1 ? '' : 's'} to '
                  '“${playlist.name}”'
              : 'Already in “${playlist.name}”')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAndAdd() async {
    final name = _newName.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final deps = ref.read(appDepsProvider);
      final playlist = await deps.playlists.create(name);
      await deps.playlists.addTracks(playlist.id, widget.trackIds);
      _newName.clear();
      navigator.pop();
      messenger.showSnackBar(SnackBar(
          content:
              Text('Created “${playlist.name}” and added '
                  '${widget.trackIds.length} track${widget.trackIds.length == 1 ? '' : 's'}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Add to playlist',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newName,
                    decoration: const InputDecoration(
                      hintText: 'Or create a new playlist…',
                      prefixIcon: Icon(Icons.playlist_add),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _createAndAdd(),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _createAndAdd,
                  child: const Text('Create & add'),
                ),
              ],
            ),
            const Divider(),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()))
            else if (_playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No playlists yet — create one above to add your tracks.'),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _playlists.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final pl = _playlists[i];
                    final hasAll = _alreadyIn.contains(pl.id);
                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(pl.name),
                      subtitle: hasAll
                          ? const Text('All selected tracks already here')
                          : null,
                      trailing:
                          hasAll ? const Icon(Icons.check_circle) : null,
                      onTap: hasAll ? null : () => _add(pl),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
