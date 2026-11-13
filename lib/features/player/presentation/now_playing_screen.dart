import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/features/player/domain/playback_controller.dart';
import 'package:music_player/shared/widgets/artwork_image.dart';

/// Full-screen player: artwork, position, transport, shuffle/repeat,
/// volume, speed and queue info.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  late final PlaybackController _player;
  late final dynamic _subs;
  dynamic _current;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _shuffle = false;
  PlayerRepeatMode _repeat = PlayerRepeatMode.off;
  double _volume = 1.0;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _player = ref.read(playerProvider);
    final subs = <dynamic>[
      _player.currentTrackStream.listen((t) => setState(() => _current = t)),
      _player.playingStream.listen((p) => setState(() => _playing = p)),
      _player.positionStream.listen((p) => setState(() => _position = p)),
      _player.durationStream.listen((d) => setState(() => _duration = d ?? Duration.zero)),
    ];
    _subs = subs;
    setState(() {
      _shuffle = _player.shuffle;
      _repeat = _player.repeatMode;
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60);
    final h = d.inHours;
    final s = d.inSeconds.remainder(60);
    final core = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return h > 0 ? '$h:$core' : core;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = _current;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Now Playing'),
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            tooltip: 'Queue: ${_player.queue.length} track(s)',
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Queue: ${_player.queue.length} track(s)')),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 260,
                    height: 260,
                    child: track == null
                        ? const Icon(Icons.music_note, size: 96)
                        : ArtworkImage(artworkId: track.artworkRef, size: 260),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (track == null)
                const Text('Nothing playing')
              else ...[
                Text(track.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('${track.artist} · ${track.album}',
                    style: TextStyle(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                Slider(
                  value: _duration.inMilliseconds == 0 ? 0 : _position.inMilliseconds / _duration.inMilliseconds,
                  onChanged: _duration.inMilliseconds == 0
                      ? null
                      : (v) => _player.seek(Duration(milliseconds: (v * _duration.inMilliseconds).round())),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(_position)),
                    Text(_fmt(_duration)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(_shuffle ? Icons.shuffle_on : Icons.shuffle),
                      color: _shuffle ? scheme.primary : null,
                      onPressed: () async {
                        await _player.setShuffle(!_shuffle);
                        setState(() => _shuffle = !_shuffle);
                      },
                    ),
                    IconButton(icon: const Icon(Icons.skip_previous), iconSize: 40, onPressed: _player.playPrevious),
                    IconButton(
                      icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 64),
                      onPressed: _player.togglePlayPause,
                    ),
                    IconButton(icon: const Icon(Icons.skip_next), iconSize: 40, onPressed: _player.playNext),
                    IconButton(
                      icon: Icon(_repeatIcon(_repeat)),
                      color: _repeat != PlayerRepeatMode.off ? scheme.primary : null,
                      onPressed: () async {
                        final next = _repeat == PlayerRepeatMode.off
                            ? PlayerRepeatMode.all
                            : _repeat == PlayerRepeatMode.all
                                ? PlayerRepeatMode.track
                                : PlayerRepeatMode.off;
                        await _player.setRepeatMode(next);
                        setState(() => _repeat = next);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.volume_down, size: 20),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: (v) {
                          _player.setVolume(v);
                          setState(() => _volume = v);
                        },
                      ),
                    ),
                    const Icon(Icons.volume_up, size: 20),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Speed: '),
                    for (final s in [0.75, 1.0, 1.25, 1.5])
                      ChoiceChip(
                        label: Text('$s'),
                        selected: _speed == s,
                        onSelected: (_) async {
                          await _player.setSpeed(s);
                          setState(() => _speed = s);
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _repeatIcon(PlayerRepeatMode mode) {
    switch (mode) {
      case PlayerRepeatMode.off:
        return Icons.repeat;
      case PlayerRepeatMode.all:
        return Icons.repeat;
      case PlayerRepeatMode.track:
        return Icons.repeat_one;
    }
  }
}
