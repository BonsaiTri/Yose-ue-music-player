import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/database/database.dart';

final _uuid = Uuid();

class TrackRepository {
  TrackRepository(this.db);
  final AppDatabase db;

  Future<List<Track>> tracks({
    String orderBy = 'date_added DESC',
    int limit = 200,
    int offset = 0,
    Expression<bool>? where,
  }) async {
    final query = db.select(db.tracks)..limit(limit, offset: offset);
    if (where != null) query.where((t) => where);
    query.orderBy([(t) => _orderTerm(t, orderBy)]);
    return query.get();
  }

  Future<int> trackCount({Expression<bool>? where}) async {
    final countExpr = countAll();
    var q = db.selectOnly(db.tracks)..addColumns([countExpr]);
    if (where != null) q.where(where);
    final row = await q.getSingle();
    return row.read(countExpr) ?? 0;
  }

  Future<List<Track>> byArtist(String artistId, {int limit = 500}) =>
      (db.select(db.tracks)
        ..where((t) => t.artistId.equals(artistId))
        ..orderBy([(t) => OrderingTerm.asc(t.discNumber, nulls: NullsOrder.last),
                   (t) => OrderingTerm.asc(t.trackNumber, nulls: NullsOrder.last)])
        ..limit(limit))
          .get();

  Future<List<Track>> byGenre(String genreId, {int limit = 500}) =>
      (db.select(db.tracks)
        ..where((t) => t.genreId.equals(genreId))
        ..orderBy([(t) => OrderingTerm.asc(t.title)]))
          .get();

  Future<List<Track>> byAlbum(String albumId, {int limit = 500}) =>
      (db.select(db.tracks)
        ..where((t) => t.albumId.equals(albumId))
        ..orderBy([(t) => OrderingTerm.asc(t.discNumber, nulls: NullsOrder.last),
                   (t) => OrderingTerm.asc(t.trackNumber, nulls: NullsOrder.last)])
        ..limit(limit))
          .get();

  Future<List<Track>> recentlyAdded({int limit = 50}) =>
      (db.select(db.tracks)
        ..orderBy([(t) => OrderingTerm.desc(t.dateAdded)])
        ..limit(limit))
          .get();

  Future<List<Track>> recentlyPlayed({int limit = 50}) =>
      (db.select(db.tracks)
        ..where((t) => t.lastPlayedAt.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.lastPlayedAt)])
        ..limit(limit))
          .get();

  Future<List<Track>> mostPlayed({int limit = 50}) =>
      (db.select(db.tracks)
        ..orderBy([(t) => OrderingTerm.desc(t.playCount)])
        ..limit(limit))
          .get();

  Future<List<Track>> favorites({int limit = 500}) async {
    final favIds = await db.select(db.favorites).get();
    if (favIds.isEmpty) return const [];
    return (db.select(db.tracks)
          ..where((t) => t.id.isIn(favIds.map((f) => f.trackId).toSet()))
          ..limit(limit))
        .get();
  }

  Future<Track?> byId(String id) =>
      (db.select(db.tracks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Track>> search(String query, {int limit = 200}) async {
    final ids = await db.searchTracksIds(query, limit: limit);
    if (ids.isEmpty) return const [];
    final tracks = await (db.select(db.tracks)..where((t) => t.id.isIn(ids))).get();
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    tracks.sort((a, b) => (order[a.id] ?? 0).compareTo(order[b.id] ?? 0));
    return tracks;
  }

  /// Registers a track. Returns the stored track.
  Future<Track> upsert(Track track) async {
    await db.into(db.tracks).insert(track, mode: InsertMode.insertOrReplace);
    return track;
  }

  /// Duplicate check: same content hash or same source identifier.
  Future<Track?> findDuplicate({required String? contentHash, required String? sourceId}) async {
    final conditions = <Expression<bool>>[];
    if (contentHash != null) {
      conditions.add(db.tracks.contentHash.equals(contentHash));
    }
    if (sourceId != null) {
      conditions.add(
        db.tracks.sourceId.equals(sourceId) & db.tracks.sourceType.equals('local').not(),
      );
    }
    if (conditions.isEmpty) return null;
    final q = db.select(db.tracks)
      ..where((t) => conditions.fold<Expression<bool>>(conditions.first, (a, b) => a | b));
    return q.getSingleOrNull();
  }

  /// Deletes the library record only. The physical audio file is untouched;
  /// deletion of files is an explicit, separate operation.
  Future<void> deleteRecord(String id) async {
    await (db.delete(db.tracks)..where((t) => t.id.equals(id))).go();
  }

  /// Removes a track from the library. With [deleteFile] the physical audio
  /// file is deleted as well. Orphaned artist/album/genre rows (no remaining
  /// tracks reference them) are cleaned up. The FTS index stays in sync via
  /// its AFTER DELETE trigger.
  Future<void> removeTrack(String id, {bool deleteFile = false}) async {
    final track = await byId(id);
    if (track == null) return;
    if (deleteFile) {
      try {
        final file = File(track.filePath);
        if (await file.exists()) await file.delete();
      } catch (e) {
        AppLogger.warning('Could not delete file ${track.filePath}: $e',
            tag: 'library');
      }
    }
    await db.transaction(() async {
      await deleteRecord(id);
      final artistId = track.artistId;
      if (artistId != null &&
          await trackCount(where: db.tracks.artistId.equals(artistId)) == 0) {
        await (db.delete(db.artists)..where((a) => a.id.equals(artistId))).go();
      }
      final albumId = track.albumId;
      if (albumId != null &&
          await trackCount(where: db.tracks.albumId.equals(albumId)) == 0) {
        await (db.delete(db.albums)..where((a) => a.id.equals(albumId))).go();
      }
      final genreId = track.genreId;
      if (genreId != null &&
          await trackCount(where: db.tracks.genreId.equals(genreId)) == 0) {
        await (db.delete(db.genres)..where((g) => g.id.equals(genreId))).go();
      }
    });
  }

  Future<void> toggleFavorite(String id, {DateTime? at}) async {
    final existing = await (db.select(db.tracks)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing == null) return;
    final favorite = !existing.favorite;
    await db.transaction(() async {
      await (db.update(db.tracks)
            ..where((t) => t.id.equals(id)))
          .write(TracksCompanion(favorite: Value(favorite)));
      if (favorite) {
        await db.into(db.favorites).insert(
            Favorite(trackId: id, addedAt: at ?? DateTime.now()));
      } else {
        await (db.delete(db.favorites)..where((f) => f.trackId.equals(id))).go();
      }
    });
  }

  Future<void> recordPlayed(String id, {int positionMs = 0}) async {
    await db.transaction(() async {
      final t = await (db.select(db.tracks)..where((x) => x.id.equals(id))).getSingleOrNull();
      if (t == null) return;
      await (db.update(db.tracks)..where((x) => x.id.equals(id))).write(
            TracksCompanion(
              playCount: Value(t.playCount + 1),
              lastPlayedAt: Value(DateTime.now()),
            ),
          );
      await db
          .into(db.playbackHistory)
          .insert(PlaybackHistoryCompanion.insert(
              trackId: id, playedAt: DateTime.now(), positionMs: Value(positionMs)));
    });
  }

  Future<void> recordSkipped(String id) async {
    final t = await (db.select(db.tracks)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (t == null) return;
    await (db.update(db.tracks)..where((x) => x.id.equals(id)))
        .write(TracksCompanion(skipCount: Value(t.skipCount + 1)));
  }

  /// Batch availability updates used by drive-connect/reconnect workflows.
  Future<void> setAvailability(Iterable<String> ids, FileAvailability status) {
    final set = ids.toSet();
    if (set.isEmpty) return Future.value();
    return (db.update(db.tracks)..where((t) => t.id.isIn(set)))
        .write(TracksCompanion(fileAvailability: Value(status)));
  }

  /// Returns tracks whose recorded file no longer exists on disk.
  Future<List<Track>> missingFiles() async {
    final all = await db.select(db.tracks).get();
    return all.where((t) => !File(t.filePath).existsSync()).toList();
  }

  /// Tracks flagged as offline/unreachable, for reconnect reconciliation.
  Future<List<Track>> offlineTracks() => (db.select(db.tracks)
        ..where((t) => t.fileAvailability.isInValues(const [
              FileAvailability.offline,
              FileAvailability.unreachable,
              FileAvailability.missing,
            ])))
      .get();

  Future<List<Track>> allTracks() => db.select(db.tracks).get();

  /// Bulk register (one transaction) for import pipeline use.
  Future<void> bulkRegister(List<Track> tracks) async {
    await db.transaction(
        () => db.batch((b) =>
            b.insertAll(db.tracks, tracks, mode: InsertMode.insertOrReplace)));
  }

  /// Re-checks file existence for every track and updates availability.
  /// Used after reconnecting external drives. Returns count updated.
  Future<int> updateAvailabilityForAll() async {
    final all = await allTracks();
    final available = <String>[];
    final offline = <String>[];
    for (final t in all) {
      if (File(t.filePath).existsSync()) {
        available.add(t.id);
      } else {
        offline.add(t.id);
      }
    }
    await setAvailability(available, FileAvailability.available);
    await setAvailability(offline, FileAvailability.offline);
    return all.length;
  }

  OrderingTerm _orderTerm($TracksTable t, String orderBy) {
    switch (orderBy) {
      case 'title':
        return OrderingTerm.asc(t.title);
      case 'artist':
        return OrderingTerm.asc(t.artist);
      case 'album':
        return OrderingTerm.asc(t.album);
      case 'genre':
        return OrderingTerm.asc(t.genre);
      case 'play_count':
        return OrderingTerm.desc(t.playCount);
      case 'last_played':
        return OrderingTerm.desc(t.lastPlayedAt, nulls: NullsOrder.last);
      case 'duration':
        return OrderingTerm.asc(t.durationMs);
      default:
        return OrderingTerm.desc(t.dateAdded);
    }
  }
}

class ArtistRepository {
  ArtistRepository(this.db);
  final AppDatabase db;

  Future<List<Artist>> all() =>
      (db.select(db.artists)..orderBy([(a) => OrderingTerm.asc(a.nameSort)])).get();

  Future<Artist> upsertByName(String name, {String? artworkRef}) async {
    final normalized = name.trim();
    final sort = normalized.toLowerCase();
    final existing = await (db.select(db.artists)..where((a) => a.nameSort.equals(sort))).getSingleOrNull();
    if (existing != null) {
      if (artworkRef != null && existing.artworkRef == null) {
        await (db.update(db.artists)..where((a) => a.id.equals(existing.id)))
            .write(ArtistsCompanion(artworkRef: Value<String?>(artworkRef)));
        return existing.copyWith(artworkRef: Value(artworkRef));
      }
      return existing;
    }
    final artist = Artist(
      id: _uuid.v4(),
      name: normalized,
      nameSort: sort,
      artworkRef: artworkRef,
      dateAdded: DateTime.now(),
    );
    await db.into(db.artists).insert(artist);
    return artist;
  }

  Future<Artist?> byId(String? id) =>
      id == null ? Future.value(null) : (db.select(db.artists)..where((a) => a.id.equals(id))).getSingleOrNull();
}

class AlbumRepository {
  AlbumRepository(this.db);
  final AppDatabase db;

  Future<List<Album>> all() =>
      (db.select(db.albums)..orderBy([(a) => OrderingTerm.asc(a.title)])).get();

  Future<Album> upsert({
    required String title,
    required String artistId,
    String? albumArtist,
    int? releaseYear,
    String? genre,
    String? artworkRef,
  }) async {
    final existing = await (db.select(db.albums)
          ..where((a) => a.title.equals(title) & a.artistId.equals(artistId)))
        .getSingleOrNull();
    if (existing != null) {
      if (artworkRef != null && existing.artworkRef == null) {
        await (db.update(db.albums)..where((a) => a.id.equals(existing.id)))
            .write(AlbumsCompanion(artworkRef: Value<String?>(artworkRef)));
        return existing.copyWith(artworkRef: Value(artworkRef));
      }
      return existing;
    }
    final album = Album(
      id: _uuid.v4(),
      title: title,
      artistId: artistId,
      albumArtist: albumArtist,
      releaseYear: releaseYear,
      genre: genre,
      artworkRef: artworkRef,
      dateAdded: DateTime.now(),
    );
    await db.into(db.albums).insert(album);
    return album;
  }

  Future<Album?> byId(String id) =>
      (db.select(db.albums)..where((a) => a.id.equals(id))).getSingleOrNull();
}

class GenreRepository {
  GenreRepository(this.db);
  final AppDatabase db;

  Future<List<Genre>> all() =>
      (db.select(db.genres)..orderBy([(g) => OrderingTerm.asc(g.name)])).get();

  Future<Genre> upsertByName(String name) async {
    final normalized = name.trim();
    final existing = await (db.select(db.genres)..where((g) => g.name.equals(normalized))).getSingleOrNull();
    if (existing != null) return existing;
    final genre = Genre(id: _uuid.v4(), name: normalized);
    await db.into(db.genres).insert(genre);
    return genre;
  }
}
