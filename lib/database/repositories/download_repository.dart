import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:music_player/database/database.dart';

final _uuid = Uuid();

class DownloadRepository {
  DownloadRepository(this.db);
  final AppDatabase db;

  Stream<List<DownloadTask>> watchActive() => (db.select(db.downloadTasks)
        ..where((t) =>
            t.status.isInValues(const [
              DownloadTaskStatus.preparing,
              DownloadTaskStatus.downloading,
              DownloadTaskStatus.processing,
              DownloadTaskStatus.validating,
            ])))
      .watch();

  /// All tasks currently in [status].
  Future<List<DownloadTask>> byStatus(DownloadTaskStatus status) =>
      (db.select(db.downloadTasks)
          ..where((t) => t.status.equalsValue(status)))
          .get();

  Future<List<DownloadTask>> queued({int limit = 50}) =>
      (db.select(db.downloadTasks)
          ..where((t) => t.status.equalsValue(DownloadTaskStatus.queued))
          ..orderBy([(t) => OrderingTerm.desc(t.priority),
                     (t) => OrderingTerm.asc(t.createdAt)])
          ..limit(limit))
          .get();

  Future<List<DownloadTask>> paused() =>
      (db.select(db.downloadTasks)..
          where((t) => t.status.equalsValue(DownloadTaskStatus.paused))..
          orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .get();

  /// Every task that ended in a failed state (newest first).
  Future<List<DownloadTask>> failed() =>
      (db.select(db.downloadTasks)
          ..where((t) => t.status.equalsValue(DownloadTaskStatus.failed))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .get();

  Future<List<DownloadTask>> history({int limit = 100}) =>
      (db.select(db.downloadTasks)
          ..where((t) =>
              t.status.isInValues(const [
                DownloadTaskStatus.completed,
                DownloadTaskStatus.failed,
                DownloadTaskStatus.cancelled,
              ]))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(limit))
      .get();

  Future<DownloadTask?> byId(String id) =>
      (db.select(db.downloadTasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// The most recent completed task with exactly [url], if any.
  /// All tasks whose status is in [statuses], newest first. Used for
  /// duplicate detection, where the stored URL may be a format variant of
  /// the queried URL and must be compared in canonical form in memory.
  Future<List<DownloadTask>> byStatuses(List<DownloadTaskStatus> statuses) =>
      (db.select(db.downloadTasks)
          ..where((t) => t.status.isInValues(statuses))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .get();

  Future<DownloadTask?> completedByUrl(String url) =>
      (db.select(db.downloadTasks)
          ..where((t) =>
              t.url.equals(url) &
              t.status.equalsValue(DownloadTaskStatus.completed))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(1))
          .getSingleOrNull();

  /// Any queued, active, or paused task with exactly [url], if any.
  Future<DownloadTask?> openByUrl(String url) =>
      (db.select(db.downloadTasks)
          ..where((t) =>
              t.url.equals(url) &
              t.status.isInValues(const [
                DownloadTaskStatus.queued,
                DownloadTaskStatus.preparing,
                DownloadTaskStatus.downloading,
                DownloadTaskStatus.processing,
                DownloadTaskStatus.paused,
              ]))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(1))
          .getSingleOrNull();

  Future<DownloadTask> create({
    required String url,
    required String title,
    String artist = 'Unknown Artist',
    String album = 'Unknown Album',
    String? sourceId,
    String? trackId,
    String? playlistId,
    int priority = 0,
  }) async {
    final now = DateTime.now();
    final task = DownloadTask(
      id: _uuid.v4(),
      trackId: trackId,
      playlistId: playlistId,
      url: url,
      title: title,
      artist: artist,
      album: album,
      status: DownloadTaskStatus.queued,
      priority: priority,
      progress: 0,
      bytesDone: 0,
      speedBps: 0,
      createdAt: now,
      updatedAt: now,
    );
    await db.into(db.downloadTasks).insert(task);
    return task;
  }

  Future<void> updateStatus(
    String id,
    DownloadTaskStatus status, {
    double? progress,
    int? bytesDone,
    int? bytesExpected,
    int? speedBps,
    String? error,
    String? tempPath,
    String? finalPath,
    String? trackId,
    bool clearError = false,
  }) async {
    await (db.update(db.downloadTasks)..where((t) => t.id.equals(id))).write(
          DownloadTasksCompanion(
            status: Value(status),
            progress: progress == null ? const Value.absent() : Value(progress),
            bytesDone: bytesDone == null ? const Value.absent() : Value(bytesDone),
            bytesExpected:
                bytesExpected == null ? const Value.absent() : Value(bytesExpected),
            speedBps: speedBps == null ? const Value.absent() : Value(speedBps),
            error: error != null
                ? Value(error)
                : (clearError ? const Value<String?>(null) : const Value.absent()),
            tempPath: tempPath == null ? const Value.absent() : Value(tempPath),
            finalPath: finalPath == null ? const Value.absent() : Value(finalPath),
            trackId: trackId == null ? const Value.absent() : Value(trackId),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  /// Cancels a task only if it is still in a cancellable state.
  Future<bool> cancel(String id) async {
    final task = await byId(id);
    if (task == null) return false;
    const cancellable = {
      DownloadTaskStatus.queued,
      DownloadTaskStatus.preparing,
      DownloadTaskStatus.downloading,
      DownloadTaskStatus.paused,
    };
    if (!cancellable.contains(task.status)) return false;
    await updateStatus(id, DownloadTaskStatus.cancelled);
    return true;
  }

  /// Deletes all terminal history records (completed, failed, cancelled).
  /// Library tracks and their files are untouched — only the download
  /// task rows go away. Returns the number of records removed.
  Future<int> clearHistory() async {
    final stmt = db.delete(db.downloadTasks)
      ..where((t) => t.status.isInValues(const [
        DownloadTaskStatus.completed,
        DownloadTaskStatus.failed,
        DownloadTaskStatus.cancelled,
      ]));
    return stmt.go();
  }

  /// Re-queues a failed, cancelled or paused task.
  Future<void> retry(String id) async {
    final task = await byId(id);
    if (task == null) return;
    if (task.status == DownloadTaskStatus.failed ||
        task.status == DownloadTaskStatus.cancelled ||
        task.status == DownloadTaskStatus.paused) {
      await updateStatus(
          id,
          DownloadTaskStatus.queued,
          progress: 0,
          bytesDone: 0,
          speedBps: 0,
          clearError: true);
    }
  }
}
