import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/platform/platform_info.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/features/downloader/presentation/downloads_screen.dart';
import 'package:music_player/features/favorites/presentation/favorites_screen.dart';
import 'package:music_player/features/listening_history/presentation/history_screen.dart';
import 'package:music_player/features/library/presentation/albums_screen.dart';
import 'package:music_player/features/library/presentation/artists_screen.dart';
import 'package:music_player/features/library/presentation/genres_screen.dart';
import 'package:music_player/features/library/presentation/library_screen.dart';
import 'package:music_player/features/media_import/presentation/import_picker.dart';
import 'package:music_player/features/player/presentation/mini_player.dart';
import 'package:music_player/features/player/presentation/now_playing_screen.dart';
import 'package:music_player/features/playlists/presentation/playlists_screen.dart';
import 'package:music_player/features/search/presentation/search_screen.dart';
import 'package:music_player/features/settings/presentation/settings_screen.dart';
import 'package:music_player/features/storage_manager/presentation/storage_screen.dart';
import 'package:music_player/shared/widgets/track_list_tile.dart';

/// Page indices used by the shell navigator.
///
/// Pages 0-4 are the primary tabs (always visible in the navigation).
/// Pages 5-11 are secondary screens reached from the Home hub.
class Page {
  Page._();
  static const int home = 0;
  static const int library = 1;
  static const int search = 2;
  static const int downloads = 3;
  static const int settings = 4;
  static const int albums = 5;
  static const int artists = 6;
  static const int genres = 7;
  static const int playlists = 8;
  static const int favorites = 9;
  static const int history = 10;
  static const int storage = 11;
}

class _NavItem {
  const _NavItem(this.title, this.icon, this.page);
  final String title;
  final IconData icon;
  final int page;
}

/// Adaptive shell: desktop sidebar (NavigationRail) on wide layouts,
/// mobile bottom navigation otherwise. A persistent mini-player sits above
/// the navigation.
///
/// Primary tabs are limited to five so both the bottom bar (mobile) and
/// the rail (desktop) stay comfortably tappable; everything else lives
/// one tap away on the Home hub.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _page = Page.home;
  bool _dragging = false;

  static const _primaryItems = [
    _NavItem('Home', Icons.home_outlined, Page.home),
    _NavItem('Library', Icons.library_music_outlined, Page.library),
    _NavItem('Search', Icons.search_outlined, Page.search),
    _NavItem('Downloads', Icons.download_outlined, Page.downloads),
    _NavItem('Settings', Icons.settings_outlined, Page.settings),
  ];

  Widget get _body {
    switch (_page) {
      case Page.home:
        return _HomePage(onNavigate: (page) => setState(() => _page = page));
      case Page.library:
        return const LibraryScreen();
      case Page.search:
        return const SearchScreen();
      case Page.downloads:
        return const DownloadsScreen();
      case Page.settings:
        return const SettingsScreen();
      case Page.albums:
        return const AlbumsScreen();
      case Page.artists:
        return const ArtistsScreen();
      case Page.genres:
        return const GenresScreen();
      case Page.playlists:
        return const PlaylistsScreen();
      case Page.favorites:
        return const FavoritesScreen();
      case Page.history:
        return const HistoryScreen();
      case Page.storage:
        return const StorageScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  void _openNowPlaying() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const NowPlayingScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 840;
    final shell = SafeArea(
      child: Column(
        children: [
          Expanded(child: isWide ? _buildRail(context) : _buildMobile(context)),
          MiniPlayer(onOpenPlayer: _openNowPlaying),
        ],
      ),
    );
    final withOverlay = Stack(
      children: [
        shell,
        if (_dragging)
          Positioned.fill(
            child: Container(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
              alignment: Alignment.center,
              child: const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.file_download_outlined, size: 32),
                      SizedBox(width: 12),
                      Text('Drop audio files to import',
                          style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    // Drag-and-drop imports (spec §6.3): drop audio files anywhere on the app.
    if (!PlatformInfo.isDesktop) return shell;
    return DropTarget(
      child: withOverlay,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragUpdated: (_) {
        if (!_dragging) setState(() => _dragging = true);
      },
      onDragDone: (details) async {
        await _importDropped(details.files.map((f) => f.path).toList());
      },
    );
  }

  Future<void> _importDropped(List<String> paths) async {
    setState(() => _dragging = false);
    if (paths.isEmpty) return;
    final result = await ref.read(appDepsProvider).importer.importPaths(paths);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(result.duplicates > 0 || result.errors > 0
          ? 'Import: ${result.added} added, ${result.duplicates} duplicates, '
              '${result.errors} error(s).'
          : 'Imported ${result.added} track(s). Visit Library to see them.'),
    ));
  }

  Widget _buildRail(BuildContext context) {
    return Row(
      children: [
        NavigationRail(
          selectedIndex: _primaryItems
              .indexWhere((i) => i.page == _page)
              .clamp(0, _primaryItems.length - 1),
          onDestinationSelected: (i) => setState(() => _page = _primaryItems[i].page),
          labelType: NavigationRailLabelType.all,
          destinations: [
            for (final item in _primaryItems)
              NavigationRailDestination(icon: Icon(item.icon), label: Text(item.title)),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Builder(
            builder: (_) => PopScope(
              canPop: false,
              child: _body,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobile(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _body),
        NavigationBar(
          selectedIndex: _primaryItems
              .indexWhere((i) => i.page == _page)
              .clamp(0, _primaryItems.length - 1),
          onDestinationSelected: (i) => setState(() => _page = _primaryItems[i].page),
          destinations: [
            for (final item in _primaryItems)
              NavigationDestination(icon: Icon(item.icon), label: item.title),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Home hub
// ---------------------------------------------------------------------------

class _HomePage extends ConsumerStatefulWidget {
  const _HomePage({required this.onNavigate});

  final void Function(int page) onNavigate;

  @override
  ConsumerState<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<_HomePage> {
  bool _loading = true;
  int _trackCount = 0;
  int _albumCount = 0;
  int _artistCount = 0;
  int _genreCount = 0;
  int _playlistCount = 0;
  int _favoriteCount = 0;
  List<Track> _recent = const [];
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = ref.read(appDepsProvider);
    final results = await Future.wait([
      deps.tracks.trackCount(),
      deps.albums.all(),
      deps.artists.all(),
      deps.genres.all(),
      deps.playlists.all(),
      deps.tracks.favorites(limit: 1000),
      deps.tracks.recentlyPlayed(limit: 8),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _trackCount = results[0] as int;
      _albumCount = (results[1] as List).length;
      _artistCount = (results[2] as List).length;
      _genreCount = (results[3] as List).length;
      _playlistCount = (results[4] as List).length;
      _favoriteCount = (results[5] as List).length;
      _recent = results[6] as List<Track>;
    });
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    final result = await pickAndImport(context, ref);
    if (!mounted) return;
    setState(() => _importing = false);
    if (result != null) await _load();
  }

  Future<List<Track>> _allTracks() =>
      ref.read(appDepsProvider).tracks.tracks(orderBy: 'date_added', limit: 50000);

  Future<void> _playAll() async {
    final all = await _allTracks();
    if (all.isNotEmpty) await ref.read(playerProvider).playQueue(all);
  }

  Future<void> _shuffleAll() async {
    final all = await _allTracks();
    if (all.isEmpty) return;
    final shuffled = List.of(all)..shuffle(Random());
    await ref.read(playerProvider).playQueue(shuffled);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yose-ue'),
        actions: [
          IconButton(
            tooltip: 'Import music',
            icon: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_upload_outlined),
            onPressed: _importing ? null : _import,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _trackCount == 0
              ? _buildOnboarding(theme)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHero(theme),
                    const SizedBox(height: 24),
                    if (_recent.isNotEmpty) ...[
                      Text('Recently played', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      for (var i = 0; i < _recent.length; i++)
                        TrackListTile(
                          track: _recent[i],
                          onTap: () => ref
                              .read(playerProvider)
                              .playQueue(_recent, startIndex: i),
                        ),
                      const SizedBox(height: 24),
                    ],
                    Text('Browse', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    _buildBrowseGrid(theme),
                  ],
                ),
    );
  }

  Widget _buildOnboarding(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset('assets/logo/logo.jpg', height: 140, fit: BoxFit.cover),
            ),
            const SizedBox(height: 24),
            Text('Welcome to ${AppConstants.appName}',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              'Your music library, offline-first.\n'
              'Import your songs to start listening.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _importing ? null : _import,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upload_file),
              label: const Text('Import music'),
            ),
            if (PlatformInfo.isDesktop) ...[
              const SizedBox(height: 12),
              Text('Tip: you can also drag & drop audio files anywhere in this window.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHero(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/logo/logo.jpg',
                      height: 56, width: 56, fit: BoxFit.cover),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppConstants.appName, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        '$_trackCount songs · $_albumCount albums · $_artistCount artists',
                        style:
                            theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _playAll,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play all'),
                ),
                OutlinedButton.icon(
                  onPressed: _shuffleAll,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseGrid(ThemeData theme) {
    final isWide = MediaQuery.sizeOf(context).width >= 840;
    final cards = [
      (Icons.album_outlined, 'Albums', _albumCount, Page.albums),
      (Icons.person_outline, 'Artists', _artistCount, Page.artists),
      (Icons.local_offer_outlined, 'Genres', _genreCount, Page.genres),
      (Icons.playlist_play_outlined, 'Playlists', _playlistCount, Page.playlists),
      (Icons.favorite_outline, 'Favorites', _favoriteCount, Page.favorites),
      (Icons.history_outlined, 'History', null, Page.history),
      (Icons.storage_outlined, 'Storage', null, Page.storage),
    ];
    return GridView.count(
      crossAxisCount: isWide ? 4 : 2,
      mainAxisExtent: isWide ? 96 : 104,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        for (final (icon, label, count, page) in cards)
          Card(
            child: InkWell(
              onTap: () => widget.onNavigate(page),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 28),
                    const SizedBox(height: 8),
                    Text(label, style: theme.textTheme.titleSmall),
                    if (count != null)
                      Text('$count',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
