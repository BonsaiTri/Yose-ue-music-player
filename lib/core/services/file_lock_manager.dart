import 'package:music_player/core/errors/app_exceptions.dart';
import 'package:music_player/core/logging/app_logger.dart';

/// Coordinates filesystem access with the player, scanner, downloader and
/// metadata extractor.
///
/// Uses reference-counted "access leases" keyed by canonical path. Destructive
/// operations (delete/move/rename/overwrite) must acquire an exclusive lease,
/// which fails if any reader/player lease is held.
enum FileAccessState { available, reading, playing, indexing, moving, deleting, unavailable }

class _Lease {
  _Lease(this.owner);
  final String owner;
  int count = 1;
}

/// Central file-operation coordinator.
///
/// Note: Dart-level coordination protects against in-process races. It does
/// not prevent another *process* from touching files; destructive operations
/// additionally verify current state immediately before acting.
class FileLockManager {
  final Map<String, _Lease> _shared = {};
  final Map<String, _Lease> _exclusive = {};

  /// Acquire a shared lease (play, read, index).
  Future<void> acquireShared(String path, String owner) async {
    final lease = _shared[path] ?? (_shared[path] = _Lease(owner));
    lease.count++;
  }

  Future<void> releaseShared(String path) async {
    final lease = _shared[path];
    if (lease == null) return;
    lease.count--;
    if (lease.count <= 0) _shared.remove(path);
  }

  /// Acquire an exclusive lease required before destructive modifications.
  /// Throws [FileOperationException] when the file is actively in use.
  Future<void> acquireExclusive(String path, String owner) async {
    final holders = <String>[
      if (_shared.containsKey(path)) 'shared:${_shared[path]!.owner}',
      if (_exclusive.containsKey(path)) 'exclusive:${_exclusive[path]!.owner}',
    ];
    if (holders.isNotEmpty) {
      throw FileOperationException(
          '$path is in use by ${holders.join(', ')}; destructive operation blocked');
    }
    _exclusive[path] = _Lease(owner);
  }

  Future<void> releaseExclusive(String path) async {
    _exclusive.remove(path);
  }

  /// Run [operation] while holding an exclusive lease, always releasing it.
  Future<T> withExclusive<T>(String path, String owner, Future<T> Function() operation) async {
    await acquireExclusive(path, owner);
    try {
      return await operation();
    } finally {
      releaseExclusive(path);
    }
  }

  /// Current state of a path (for UI indicators).
  FileAccessState stateOf(String path) {
    if (_exclusive[path]?.owner == 'deleter') return FileAccessState.deleting;
    if (_exclusive[path]?.owner == 'mover') return FileAccessState.moving;
    final shared = _shared[path];
    if (shared != null) {
      if (shared.owner == 'player') return FileAccessState.playing;
      if (shared.owner == 'indexer') return FileAccessState.indexing;
      if (shared.owner == 'reader') return FileAccessState.reading;
    }
    return FileAccessState.available;
  }

  Map<String, FileAccessState> allStates() => {
        for (final e in _shared.keys) e: stateOf(e),
        for (final e in _exclusive.keys) e: stateOf(e),
      };

  void dispose() {
    _shared.clear();
    _exclusive.clear();
    AppLogger.info('FileLockManager disposed', tag: 'filelock');
  }
}
