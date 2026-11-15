/// Application-wide constants.
class AppConstants {
  const AppConstants._();

  static const String appName = 'Yose-ue Music Player';

  /// Displayed in Settings → About; keep in sync with `pubspec.yaml`.
  static const String appVersion = '0.3.7';
  static const String databaseFileName = 'music_player.sqlite';

  /// Storage layout relative to the application data root.
  static const String dirDatabase = 'database';
  static const String dirDownloads = 'Downloads';
  static const String dirMusic = 'Music';
  static const String dirArtwork = 'Artwork';
  static const String dirCache = 'Cache';
  static const String dirBin = 'bin';
  static const String dirBackups = 'Backups';
  static const String dirLogs = 'logs';
  static const String dirTemp = 'tmp';

  /// Audio file extensions accepted by the import pipeline.
  static const Set<String> audioExtensions = {
    'mp3', 'flac', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'wma',
  };

  static const int pageSize = 50;
  static const int maxConcurrentDownloads = 3;
}
