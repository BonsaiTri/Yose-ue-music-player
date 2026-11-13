/// Base class for all application errors. Carries a stable category used by
/// diagnostics and user-facing messages.
abstract class AppException implements Exception {
  const AppException(this.message, {this.cause, required this.category});

  final String message;
  final Object? cause;
  final String category;

  @override
  String toString() =>
      '$runtimeType($category): $message${cause == null ? '' : ' | cause: $cause'}';
}

class DatabaseException extends AppException {
  const DatabaseException(super.message, {super.cause})
      : super(category: 'database');
}

class FileOperationException extends AppException {
  const FileOperationException(super.message, {super.cause})
      : super(category: 'file');
}

class MetadataException extends AppException {
  const MetadataException(super.message, {super.cause})
      : super(category: 'metadata');
}

class DownloadException extends AppException {
  const DownloadException(super.message, {super.cause})
      : super(category: 'download');
}

class PlaybackException extends AppException {
  const PlaybackException(super.message, {super.cause})
      : super(category: 'playback');
}

class StorageException extends AppException {
  const StorageException(super.message, {super.cause}) : super(category: 'storage');
}
