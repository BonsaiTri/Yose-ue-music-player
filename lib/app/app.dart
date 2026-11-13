import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/features/app_shell.dart';
import 'package:music_player/shared/themes/app_theme.dart';

class MusicPlayerApp extends ConsumerStatefulWidget {
  const MusicPlayerApp({super.key});

  @override
  ConsumerState<MusicPlayerApp> createState() => _MusicPlayerAppState();
}

/// Application root: theming plus app lifecycle handling.
///
/// Lifecycle policy:
/// - **Background (`paused`)**: playback *continues* — this is a media app,
///   and the platform audio session / audio_service keep the user in control
///   (lock screen, media keys). Interruptions are handled by the audio
///   session policy in [PlaybackController].
/// - **Teardown (`detached`)**: flush the playback state to disk immediately
///   so a killed process restores the exact queue and position.
class _MusicPlayerAppState extends ConsumerState<MusicPlayerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.detached:
        // The app is being torn down (mobile) — persist state immediately.
        final player = ref.read(appDepsProvider).player;
        AppLogger.info('App detached: flushing playback state',
            tag: 'lifecycle');
        player.flushState();
      case AppLifecycleState.paused:
      // Keep playing; nothing to do.
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
      case AppLifecycleState.resumed:
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: const AppShell(),
    );
  }
}

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);
