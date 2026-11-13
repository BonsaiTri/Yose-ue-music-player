/// Spec §6.5: provider abstraction for external music sources.
///
/// External metadata/download providers are pluggable: implement
/// [MusicSourceProvider], register instances in [AppDependencies.sources],
/// and the Search screen picks them up automatically — no restructuring
/// of the application is required to add or replace a source.
library;

/// One result returned by an external source.
class RemoteSearchResult {
  const RemoteSearchResult({
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.durationMs,
    this.artworkUri,
    required this.sourceId,
    this.downloadUri,
  });

  /// Stable identifier of the result within its source.
  final String sourceId;

  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? durationMs;

  /// Optional artwork image (displayed in search results).
  final Uri? artworkUri;

  /// Optional direct-media URL that the download engine can enqueue.
  /// Null means the source offers metadata only.
  final Uri? downloadUri;

  @override
  String toString() => 'RemoteSearchResult($title — $artist)';
}

/// A replaceable external music source (search + optional download).
abstract class MusicSourceProvider {
  const MusicSourceProvider();

  /// Unique stable id (e.g. 'example-library').
  String get id;

  /// Human-readable name shown in the source picker.
  String get label;

  /// Searches the source; implementations must never block the UI and
  /// should fail with a catchable [Exception].
  Future<List<RemoteSearchResult>> search(String query, {int limit = 20});
}

/// Ordered registry of enabled external sources.
///
/// The default registry is empty: the app is fully functional with
/// local-only search, and providers can be enabled at bootstrap without
/// touching the Search screen.
class SearchProviderRegistry {
  const SearchProviderRegistry(this.providers);

  final List<MusicSourceProvider> providers;

  MusicSourceProvider? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}
