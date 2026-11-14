package com.musicplayer.music_player

import com.ryanheise.audioservice.AudioServiceActivity

/// Inherits audio_service's AudioServiceActivity so the plugin's shared
/// FlutterEngine is the same engine that hosts this activity. A plain
/// FlutterActivity here makes audio_service create a second, detached engine
/// and reject every method channel call ("wrong engine" IllegalStateException).
class MainActivity : AudioServiceActivity()
