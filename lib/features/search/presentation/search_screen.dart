import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/search/domain/search_provider.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// Search with a pluggable source (spec §6.5): the local library by
/// default, plus any external [MusicSourceProvider]s registered in
/// [AppDependencies.sources].
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _sourceId = 'library';
  List<Track> _results = const [];
  List<RemoteSearchResult> _remoteResults = const [];
  bool _searching = false;
  String? _error;

  MusicSourceProvider? get _remoteSource {
    final registry = ref.read(appDepsProvider).sources;
    if (_sourceId == 'library') return null;
    return registry.byId(_sourceId);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = const [];
        _remoteResults = const [];
        _searching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    final remote = _remoteSource;
    if (remote != null) {
      try {
        final results = await remote.search(query);
        if (!mounted) return;
        setState(() {
          _remoteResults = results;
          _results = const [];
          _searching = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _error = 'Source "${remote.label}" failed: $e';
          _remoteResults = const [];
          _results = const [];
        });
      }
      return;
    }
    final results = await ref.read(appDepsProvider).tracks.search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _remoteResults = const [];
      _searching = false;
    });
  }

  Future<void> _queueDownload(RemoteSearchResult r) async {
    final uri = r.downloadUri;
    if (uri == null) return;
    final title = r.title.replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '').trim();
    await ref.read(appDepsProvider).downloader.queue(
      url: uri.toString(),
      title: title.isEmpty ? r.title : title,
      artist: r.artist,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Queued for download.')));
    }
  }

  /// Duplicate check against the local library (spec §6.5).
  Future<bool> _inLibrary(RemoteSearchResult r) async {
    final matches = await ref
        .read(appDepsProvider)
        .tracks
        .search('${r.title} ${r.artist}');
    return matches.any((t) =>
        t.title.toLowerCase() == r.title.toLowerCase() &&
        (t.artist.toLowerCase() == r.artist.toLowerCase() ||
            t.albumArtist?.toLowerCase() == r.albumArtist?.toLowerCase()));
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.read(appDepsProvider).sources.providers;
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          // The source picker only appears when an external source is
          // registered — with just the local library it is noise.
          if (sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: ButtonTheme(
                        height: 36,
                        child: DropdownButton<String>(
                          value: _sourceId,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                                value: 'library', child: Text('Library')),
                            for (final s in sources)
                              DropdownMenuItem(value: s.id, child: Text(s.label)),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _sourceId = v;
                              _results = const [];
                              _remoteResults = const [];
                              _error = null;
                            });
                            if (_controller.text.trim().isNotEmpty) {
                              _search(_controller.text);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: 'Search title, artist, album, genre…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _onChanged,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _remoteSource != null
                    ? _remoteResults.isEmpty
                        ? Center(
                            child: Text(sources.isEmpty
                                ? 'No external sources are configured.'
                                : 'No results from "${_remoteSource!.label}".'),
                          )
                        : ListView.builder(
                            itemCount: _remoteResults.length,
                            itemBuilder: (_, i) =>
                                _RemoteResultTile(
                                  result: _remoteResults[i],
                                  onQueueDownload: _queueDownload,
                                  inLibraryChecker: _inLibrary,
                                ),
                          )
                    : _results.isEmpty
                        ? const Center(child: Text('Type to search your library.'))
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (_, i) => TrackListTile(
                              track: _results[i],
                              onTap: () => ref
                                  .read(playerProvider)
                                  .playQueue(_results, startIndex: i),
                              onRemove: (deleteFile) async {
                                await ref
                                    .read(appDepsProvider)
                                    .tracks
                                    .removeTrack(_results[i].id,
                                        deleteFile: deleteFile);
                                await _search(_controller.text);
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _RemoteResultTile extends StatefulWidget {
  const _RemoteResultTile({
    required this.result,
    required this.onQueueDownload,
    required this.inLibraryChecker,
  });

  final RemoteSearchResult result;
  final Future<void> Function(RemoteSearchResult) onQueueDownload;
  final Future<bool> Function(RemoteSearchResult) inLibraryChecker;

  @override
  State<_RemoteResultTile> createState() => _RemoteResultTileState();
}

class _RemoteResultTileState extends State<_RemoteResultTile> {
  bool _inLibrary = false;

  @override
  void initState() {
    super.initState();
    widget.inLibraryChecker(widget.result)
        .then((v) => setState(() => _inLibrary = v));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return ListTile(
      leading: r.artworkUri != null
          ? CircleAvatar(
              radius: 20,
              child: ClipOval(
                child: Image.network(r.artworkUri!.toString(),
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.music_note)),
              ),
            )
          : const CircleAvatar(child: Icon(Icons.music_note)),
      title: Text(r.title),
      subtitle: Text([
        r.artist,
        if (r.album != null) r.album,
        if (r.durationMs != null) _fmt(r.durationMs!),
      ].join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_inLibrary)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('In library', style: TextStyle(fontSize: 12)),
            ),
          if (r.downloadUri != null)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Queue download',
              onPressed: () => widget.onQueueDownload(r),
            ),
        ],
      ),
    );
  }

  static String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
