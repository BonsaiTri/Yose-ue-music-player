import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';

/// Snapshot of playback state persisted across restarts.
class PlaybackStateRecord {
  const PlaybackStateRecord({
    required this.trackId,
    required this.positionMs,
    required this.queueIds,
    required this.index,
    required this.shuffle,
    required this.repeatMode,
  });

  final String trackId;
  final int positionMs;
  final List<String> queueIds;
  final int index;
  final bool shuffle;
  final String repeatMode;

  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'positionMs': positionMs,
        'queueIds': queueIds,
        'index': index,
        'shuffle': shuffle,
        'repeatMode': repeatMode,
      };

  static PlaybackStateRecord? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final trackId = json['trackId'] as String?;
    final queueIds = (json['queueIds'] as List?)?.cast<String>();
    if (trackId == null || queueIds == null || queueIds.isEmpty) return null;
    return PlaybackStateRecord(
      trackId: trackId,
      positionMs: (json['positionMs'] as int?) ?? 0,
      queueIds: queueIds,
      index: (json['index'] as int?) ?? 0,
      shuffle: (json['shuffle'] as bool?) ?? false,
      repeatMode: (json['repeatMode'] as String?) ?? 'off',
    );
  }
}

/// App-level repeat semantics (mapped onto just_audio's LoopMode).
enum PlayerRepeatMode { off, all, track }

/// audio_service 0.18 handler: bridges just_audio's AudioPlayer to the
/// system media notification (lock screen / media session).
class PlaybackHandler extends BaseAudioHandler {
  PlaybackHandler(this.player);

  final AudioPlayer player;

  /// Resolves an artwork id (library `artworkRef`) to an absolute file
  /// path, used as the media notification's large icon (lock screen art).
  Future<String?> Function(String?)? artworkPathFor;

  /// The library queue currently loaded (owned by PlaybackController).
  List<Track> libraryQueue = [];

  Track? get currentTrack {
    final i = player.currentIndex ?? -1;
    if (i < 0 || i >= libraryQueue.length) return null;
    return libraryQueue[i];
  }

  /// App-level repeat mode (see [PlayerRepeatMode]).
  PlayerRepeatMode repeatMode = PlayerRepeatMode.off;

  final _subs = <StreamSubscription<dynamic>>[];

  Future<void> bind() async {
    _subs.add(player.playingStream.listen((_) => _publishState()));
    _subs.add(player.processingStateStream.listen((_) => _publishState()));
    _subs.add(player.positionStream.listen((_) => _publishState()));
    _subs.add(player.currentIndexStream.listen((_) => _publishItem()));
    _publishState();
    _publishItem();
  }

  void _publishState() {
    playbackState.value = PlaybackState(
      playing: player.playing,
      processingState: _processingState(player.processingState),
      updatePosition: player.position,
      speed: player.speed,
      updateTime: DateTime.now(),
      repeatMode: _serviceRepeatMode(repeatMode),
      shuffleMode: player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      queueIndex: player.currentIndex,
      controls: const [
        MediaControl.play,
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        MediaControl.fastForward,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.playPause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
    );
  }

  static AudioServiceRepeatMode _serviceRepeatMode(PlayerRepeatMode mode) {
    switch (mode) {
      case PlayerRepeatMode.off:
        return AudioServiceRepeatMode.none;
      case PlayerRepeatMode.track:
        return AudioServiceRepeatMode.one;
      case PlayerRepeatMode.all:
        return AudioServiceRepeatMode.all;
    }
  }

  static AudioProcessingState _processingState(ProcessingState s) {
    switch (s) {
      case ProcessingState.loading:
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }

  Future<void> _publishItem() async {
    final track = currentTrack;
    if (track == null) {
      mediaItem.value = null;
      queue.value = const [];
      queueTitle.value = '';
      return;
    }
    // Best-effort: a missing artwork file must never break publishing the
    // media item (the notification just falls back to the app icon).
    String? artPath;
    final resolver = artworkPathFor;
    if (resolver != null) {
      try {
        artPath = await resolver(track.artworkRef);
      } catch (_) {
        artPath = null;
      }
    }
    mediaItem.value = MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration:
          track.durationMs > 0 ? Duration(milliseconds: track.durationMs) : null,
      artUri: artPath == null ? null : Uri.file(artPath),
    );
    queue.value = [
      for (final t in libraryQueue)
        MediaItem(id: t.id, title: t.title, artist: t.artist)
    ];
    queueTitle.value = track.album;
  }

  // -- transport ---------------------------------------------------------

  @override
  Future<void> play() async {
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    await player.seekToPrevious();
  }

  @override
  Future<void> fastForward() async {
    await player.seek(player.position + const Duration(seconds: 15));
  }

  @override
  Future<void> rewind() async {
    await player.seek(player.position - const Duration(seconds: 10));
  }

  @override
  Future<void> setSpeed(double speed) async {
    await player.setSpeed(speed);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await player
        .setShuffleModeEnabled(shuffleMode == AudioServiceShuffleMode.all);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await setRepeat(repeatMode == AudioServiceRepeatMode.one
        ? PlayerRepeatMode.track
        : repeatMode == AudioServiceRepeatMode.all
            ? PlayerRepeatMode.all
            : PlayerRepeatMode.off);
  }

  Future<void> setRepeat(PlayerRepeatMode mode) async {
    repeatMode = mode;
    await player.setLoopMode(
      switch (mode) {
        PlayerRepeatMode.off => LoopMode.off,
        PlayerRepeatMode.track => LoopMode.one,
        PlayerRepeatMode.all => LoopMode.all,
      },
    );
    _publishState();
  }

  Future<void> unbind() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  Future<void> disposeHandler() async {
    await unbind();
    await player.dispose();
  }
}

/// Central playback engine wrapping just_audio + audio_service.
///
/// Queue, shuffle and repeat are delegated to just_audio's
/// ConcatenatingAudioSource; position persistence survives restarts.
class PlaybackController {
  PlaybackController(
      {required String stateDir,
      required this.tracksRepo,
      this.artworkPathFor})
      : _stateFile = File('$stateDir/playback_state.json'),
        _handler = PlaybackHandler(AudioPlayer()) {
    _handler.artworkPathFor = artworkPathFor;
  }

  final TrackRepository tracksRepo;

  /// Artwork id -> absolute path resolver (lock screen art).
  final Future<String?> Function(String?)? artworkPathFor;
  final File _stateFile;
  final PlaybackHandler _handler;

  AudioPlayer get player => _handler.player;
  PlaybackHandler get handler => _handler;

  List<Track> get queue => _handler.libraryQueue;
  set queue(List<Track> value) => _handler.libraryQueue = value;

  bool get shuffle => player.shuffleModeEnabled;
  PlayerRepeatMode get repeatMode => _handler.repeatMode;

  Stream<Duration> get positionStream => player.positionStream;
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<bool> get playingStream => player.playingStream;

  /// Current track (null when the queue is empty).
  Track? get currentTrack {
    final i = player.currentIndex;
    if (i == null || i < 0 || i >= queue.length) return null;
    return queue[i];
  }

  Stream<Track?> get currentTrackStream =>
      player.currentIndexStream.map((_) => currentTrack);

  Timer? _saveTimer;
  bool _initialized = false;
  bool _askedNotificationPermission = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _configureAudioSession();
    await _handler.bind();
    await AudioService.init<PlaybackHandler>(
      builder: () => _handler,
      config: const AudioServiceConfig(
        androidNotificationChannelName: 'Playback',
        androidNotificationChannelDescription: 'Music playback controls',
      ),
    );
    player.currentIndexStream.listen((_) {
      _saveState();
      _recordPlay();
    });
    player.playingStream.listen((playing) {
      _saveTimer?.cancel();
      _saveTimer = null;
      if (playing) {
        // Periodic persistence while playing (bounded frequency).
        _saveTimer =
            Timer.periodic(const Duration(seconds: 5), (_) => _saveState());
      } else {
        _saveState();
      }
    });
  }

  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
    ));
    // Explicit interruption policy (spec 17.3):
    //  - transient interruptions pause; resume only when the platform says so
    //  - permanent interruptions (device removed) leave playback paused.
    var pausedByInterruption = false;
    session.interruptionEventStream.listen((event) async {
      if (event.begin) {
        if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.unknown) {
          pausedByInterruption = true;
          await player.pause();
          AppLogger.info('Paused due to interruption', tag: 'playback');
        }
      } else if (pausedByInterruption) {
        pausedByInterruption = false;
        await player.play();
        AppLogger.info('Resumed after interruption', tag: 'playback');
      }
    });
  }

  /// Android 13+: without POST_NOTIFICATIONS the system drops the media
  /// notification silently, so there are no lock screen controls. Ask on
  /// first play; on older Android this auto-grants without a dialog.
  Future<void> _ensureNotificationPermission() async {
    if (_askedNotificationPermission || !Platform.isAndroid) return;
    _askedNotificationPermission = true;
    try {
      final status = await Permission.notification.request();
      if (status.isGranted) {
        AppLogger.info('Notification permission granted', tag: 'playback');
      } else {
        AppLogger.warning(
            'Notification permission ${status.name} — lock screen controls will not appear until it is granted in system settings',
            tag: 'playback');
      }
    } catch (e) {
      AppLogger.warning('Notification permission request failed: $e',
          tag: 'playback');
    }
  }

  /// Plays [tracks] starting at [startIndex].
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    await _ensureNotificationPermission();
    _handler.libraryQueue = List.of(tracks);
    _handler._publishItem();
    final source = ConcatenatingAudioSource(
      children: [for (final t in tracks) AudioSource.uri(Uri.file(t.filePath))],
    );
    await player.setAudioSource(source,
        initialIndex: startIndex.clamp(0, tracks.length - 1));
    await _handler.setRepeat(repeatMode);
    await _handler.play();
    _saveState();
  }

  Future<void> playTrack(Track track) => playQueue([track]);

  Future<void> playNext() async {
    final current = currentTrack;
    if (current != null) await tracksRepo.recordSkipped(current.id);
    await _handler.skipToNext();
  }

  Future<void> playPrevious() => _handler.skipToPrevious();

  Future<void> togglePlayPause() async {
    if (player.playing) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
  }

  Future<void> seek(Duration position) => _handler.seek(position);
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0.0, 1.0));
  Future<void> setSpeed(double speed) => _handler.setSpeed(speed);

  Future<void> setShuffle(bool value) async {
    await player.setShuffleModeEnabled(value);
    _saveState();
  }

  Future<void> setRepeatMode(PlayerRepeatMode mode) async {
    await _handler.setRepeat(mode);
    _saveState();
  }

  void _recordPlay() {
    final track = currentTrack;
    if (track != null) tracksRepo.recordPlayed(track.id);
  }

  Future<void> _saveState() async {
    final track = currentTrack;
    if (track == null) return;
    final record = PlaybackStateRecord(
      trackId: track.id,
      positionMs: player.position.inMilliseconds,
      queueIds: [for (final t in _handler.libraryQueue) t.id],
      index: player.currentIndex ?? 0,
      shuffle: shuffle,
      repeatMode: repeatMode.name,
    );
    try {
      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(jsonEncode(record.toJson()), flush: true);
    } catch (e) {
      AppLogger.warning('Failed to persist playback state: $e',
          tag: 'playback');
    }
  }

  /// Immediately persists the current queue and position (bypassing the
  /// 5-second throttle). Used on app teardown so a killed process never
  /// loses more than a few seconds of position.
  Future<void> flushState() => _saveState();

  /// Restores the last known queue and position after a restart.
  /// Playback starts paused; the user chooses to continue.
  Future<void> restore() async {
    if (!await _stateFile.exists()) return;
    try {
      final json =
          jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
      final record = PlaybackStateRecord.fromJson(json);
      if (record == null) return;
      final byId = <String, Track>{};
      for (final id in record.queueIds.toSet()) {
        final t = await tracksRepo.byId(id);
        if (t != null) byId[id] = t;
      }
      final queueTracks = [
        for (final id in record.queueIds)
          if (byId[id] != null) byId[id]!
      ];
      if (queueTracks.isEmpty) return;
      _handler.libraryQueue = List.of(queueTracks);
      _handler._publishItem();
      final source = ConcatenatingAudioSource(
        children: [
          for (final t in queueTracks) AudioSource.uri(Uri.file(t.filePath))
        ],
      );
      await player.setAudioSource(source,
          initialIndex: record.index.clamp(0, queueTracks.length - 1));
      await player.seek(Duration(milliseconds: record.positionMs));
      await player.pause();
      AppLogger.info('Restored playback state at ${record.positionMs}ms',
          tag: 'playback');
    } catch (e) {
      AppLogger.warning('Playback state restore failed: $e', tag: 'playback');
    }
  }

  Future<void> dispose() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _saveState();
    await _handler.disposeHandler();
  }
}
