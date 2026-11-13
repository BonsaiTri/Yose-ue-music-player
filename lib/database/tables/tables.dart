import 'package:drift/drift.dart';

/// Persistent file availability status for a track's audio file.
enum FileAvailability {
  available,
  offline,
  unreachable,
  missing,
  permissionDenied,
  corrupted,
}

/// Lifecycle state of a download task (persisted in the database).
enum DownloadTaskStatus {
  queued,
  preparing,
  downloading,
  processing,
  validating,
  completed,
  failed,
  cancelled,
  paused,
}

class Artists extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get name => text().named('name')();
  TextColumn get nameSort => text().named('name_sort')();
  TextColumn get artworkRef => text().nullable().named('artwork_ref')();
  DateTimeColumn get dateAdded => dateTime().named('date_added')();

  @override
  Set<Column> get primaryKey => {id};
}

class Albums extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get title => text().named('title')();
  /// Null when the album artist differs from the primary artist.
  TextColumn get artistId => text().nullable().named('artist_id')();
  TextColumn get albumArtist => text().nullable().named('album_artist')();
  IntColumn get releaseYear => integer().nullable().named('release_year')();
  TextColumn get genre => text().nullable()();
  TextColumn get artworkRef => text().nullable().named('artwork_ref')();
  DateTimeColumn get dateAdded => dateTime().named('date_added')();

  @override
  Set<Column> get primaryKey => {id};
}

class Genres extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get name => text().named('name')();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'tracks_artist', columns: {#artistId})
@TableIndex(name: 'tracks_album', columns: {#albumId})
@TableIndex(name: 'tracks_genre', columns: {#genreId})
@TableIndex(name: 'tracks_date_added', columns: {#dateAdded})
@TableIndex(name: 'tracks_last_played', columns: {#lastPlayedAt})
@TableIndex(name: 'tracks_favorite', columns: {#favorite})
@TableIndex(name: 'tracks_source_id', columns: {#sourceId})
@TableIndex(name: 'tracks_content_hash', columns: {#contentHash})
@TableIndex(name: 'tracks_file_availability', columns: {#fileAvailability})
class Tracks extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get title => text().named('title')();
  TextColumn get artist => text().named('artist')();
  TextColumn get artistId =>
      text().nullable().named('artist_id').references(Artists, #id)();
  TextColumn get album =>
      text().withDefault(const Constant('Unknown Album'))();
  TextColumn get albumId =>
      text().nullable().named('album_id').references(Albums, #id)();
  TextColumn get albumArtist => text().nullable().named('album_artist')();
  TextColumn get genreId => text().nullable().named('genre_id')();
  TextColumn get genre => text().nullable()();
  IntColumn get releaseYear => integer().nullable().named('release_year')();
  IntColumn get durationMs =>
      integer().withDefault(const Constant(0)).named('duration_ms')();
  IntColumn get trackNumber => integer().nullable().named('track_number')();
  IntColumn get discNumber => integer().nullable().named('disc_number')();
  TextColumn get filePath => text().named('file_path')();
  TextColumn get fileFormat => text().named('file_format')();
  IntColumn get fileSize => integer().nullable().named('file_size')();
  IntColumn get bitrate => integer().nullable()();
  IntColumn get sampleRate => integer().nullable().named('sample_rate')();
  IntColumn get channels => integer().nullable()();
  /// References artwork.id (never an absolute path).
  TextColumn get artworkRef => text().nullable().named('artwork_ref')();

  TextColumn get sourceId => text().nullable().named('source_id')();
  TextColumn get sourceType =>
      text().withDefault(const Constant('local')).named('source_type')();
  /// SHA-256 of the audio file, used for duplicate detection.
  TextColumn get contentHash => text().nullable().named('content_hash')();
  IntColumn get playCount =>
      integer().withDefault(const Constant(0)).named('play_count')();
  IntColumn get skipCount =>
      integer().withDefault(const Constant(0)).named('skip_count')();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastPlayedAt => dateTime().nullable().named('last_played_at')();
  DateTimeColumn get dateAdded => dateTime().named('date_added')();
  DateTimeColumn get dateModified => dateTime().named('date_modified')();
  IntColumn get fileAvailability =>
      intEnum<FileAvailability>()
          .withDefault(const Constant(0)) // FileAvailability.available
          .named('file_availability')();

  @override
  Set<Column> get primaryKey => {id};
}

class Playlists extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get name => text().named('name')();
  TextColumn get artworkRef => text().nullable().named('artwork_ref')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'playlist_tracks_order', columns: {#playlistId, #position})
class PlaylistTracks extends Table {
  TextColumn get playlistId =>
      text().named('playlist_id').references(Playlists, #id, onDelete: KeyAction.cascade)();
  TextColumn get trackId =>
      text().named('track_id').references(Tracks, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer().named('position')();

  @override
  Set<Column> get primaryKey => {playlistId, trackId};
}

class Favorites extends Table {
  TextColumn get trackId =>
      text().named('track_id').references(Tracks, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get addedAt => dateTime().named('added_at')();

  @override
  Set<Column> get primaryKey => {trackId};
}

class PlaybackHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackId =>
      text().named('track_id').references(Tracks, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get playedAt => dateTime().named('played_at')();
  IntColumn get positionMs =>
      integer().withDefault(const Constant(0)).named('position_ms')();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'download_tasks_status', columns: {#status})
class DownloadTasks extends Table {
  TextColumn get id => text().named('id')();
  /// Associated library track once registered (nullable while downloading).
  TextColumn get trackId =>
      text().nullable().named('track_id').references(Tracks, #id, onDelete: KeyAction.cascade)();
  TextColumn get url => text().named('url')();
  TextColumn get title => text().named('title')();
  TextColumn get artist =>
      text().withDefault(const Constant('Unknown Artist'))();
  TextColumn get album => text().withDefault(const Constant('Unknown Album'))();
  IntColumn get status =>
      intEnum<DownloadTaskStatus>()
          .withDefault(const Constant(0)) // DownloadTaskStatus.queued
          ();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  RealColumn get progress => real().withDefault(const Constant(0.0))();
  IntColumn get bytesExpected => integer().nullable().named('bytes_expected')();
  IntColumn get bytesDone =>
      integer().withDefault(const Constant(0)).named('bytes_done')();
  IntColumn get speedBps =>
      integer().withDefault(const Constant(0)).named('speed_bps')();
  TextColumn get error => text().nullable()();
  TextColumn get tempPath => text().nullable().named('temp_path')();
  TextColumn get finalPath => text().nullable().named('final_path')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'app_settings_key', columns: {#key}, unique: true)
class AppSettings extends Table {
  TextColumn get key => text().named('key')();
  TextColumn get value => text().named('value')();

  @override
  Set<Column> get primaryKey => {key};
}

class Artwork extends Table {
  TextColumn get id => text().named('id')();
  /// Relative path under the application storage root, e.g.
  /// "Artwork/albums/<sha256>.webp".
  TextColumn get relativePath => text().named('relative_path')();
  TextColumn get contentHash => text().named('content_hash')();
  TextColumn get mimeType => text().named('mime_type')();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  IntColumn get fileSize => integer().named('file_size')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}
