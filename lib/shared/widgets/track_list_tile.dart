import 'package:flutter/material.dart';

import 'package:music_player/database/database.dart';
import 'package:music_player/shared/widgets/artwork_image.dart';

/// Compact track row used across library, search, playlists and history.
class TrackListTile extends StatelessWidget {
  const TrackListTile({
    super.key,
    required this.track,
    required this.onTap,
    this.trailing,
    this.onRemove,
  });

  final Track track;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Optional remove action. When set, an overflow button is appended to
  /// [trailing] offering "remove (keep file)" vs "remove and delete file".
  final Future<void> Function(bool deleteFile)? onRemove;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60);
    final h = d.inHours;
    final s = d.inSeconds.remainder(60);
    final core =
        '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return h > 0 ? '$h:$core' : core;
  }

  @override
  Widget build(BuildContext context) {
    final duration = Duration(milliseconds: track.durationMs);
    return ListTile(
      onTap: onTap,
      leading: ArtworkImage(artworkId: track.artworkRef, size: 44),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.artist} · ${track.album} · ${_fmt(duration)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing == null && onRemove == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailing != null) trailing!,
                if (onRemove != null)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'More',
                    onSelected: (value) {
                      if (value == 'remove') _confirmRemove(context);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'remove', child: Text('Remove from library')),
                    ],
                  ),
              ],
            ),
    );
  }

  void _confirmRemove(BuildContext context) {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Remove from library?'),
            ),
            ListTile(
              title: const Text('Remove, keep file on disk'),
              onTap: () async {
                navigator.pop();
                await onRemove?.call(false);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Removed from library. File kept on disk.')));
              },
            ),
            ListTile(
              title: const Text(
                  'Remove and delete file',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                navigator.pop();
                await onRemove?.call(true);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Removed from library and file deleted.')));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
