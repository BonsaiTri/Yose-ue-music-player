import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/features/player/domain/playback_controller.dart';
import 'package:music_player/shared/widgets/artwork_image.dart';

/// Persistent mini-player bar shown on every screen.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, required this.onOpenPlayer});

  final VoidCallback onOpenPlayer;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  TrackRef? _current;

  TrackRef? get _track => _current;

  @override
  void initState() {
    super.initState();
    final player = ref.read(playerProvider);
    _player = player;
    _sub1 = player.currentTrackStream.listen((track) => setState(() => _current = track == null ? null : TrackRef(track)));
    _sub2 = player.playingStream.listen((p) => setState(() => _playing = p));
    _sub3 = player.positionStream.listen((p) => setState(() => _position = p));
    _sub4 = player.durationStream.listen((d) => setState(() => _duration = d ?? Duration.zero));
  }

  late final PlaybackController _player;
  late final dynamic _sub1, _sub2, _sub3, _sub4;

  @override
  void dispose() {
    _sub1.cancel();
    _sub2.cancel();
    _sub3.cancel();
    _sub4.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: widget.onOpenPlayer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ArtworkImage(artworkId: track.artworkRef, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13)),
                        Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: _player.playPrevious,
                  ),
                  IconButton(
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () => _player.togglePlayPause(),
                  ),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: _player.playNext),
                ],
              ),
              if (_duration > Duration.zero)
                LinearProgressIndicator(
                  value: _position.inMilliseconds / _duration.inMilliseconds,
                  minHeight: 2,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lightweight wrapper so the mini player does not rebuild on position
/// updates beyond the progress indicator.
class TrackRef {
  TrackRef(this.track);
  final dynamic track;
  String get title => track.title;
  String get artist => track.artist;
  String? get artworkRef => track.artworkRef;
}
