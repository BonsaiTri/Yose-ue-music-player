import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/platform/platform_info.dart';
import 'package:music_player/features/downloader/presentation/downloads_screen.dart';
import 'package:music_player/features/favorites/presentation/favorites_screen.dart';
import 'package:music_player/features/listening_history/presentation/history_screen.dart';
import 'package:music_player/features/library/presentation/library_screen.dart';
import 'package:music_player/features/library/presentation/albums_screen.dart';
import 'package:music_player/features/library/presentation/artists_screen.dart';
import 'package:music_player/features/library/presentation/genres_screen.dart';
import 'package:music_player/features/player/presentation/mini_player.dart';
import 'package:music_player/features/player/presentation/now_playing_screen.dart';
import 'package:music_player/features/playlists/presentation/playlists_screen.dart';
import 'package:music_player/features/search/presentation/search_screen.dart';
import 'package:music_player/features/settings/presentation/settings_screen.dart';
import 'package:music_player/features/storage_manager/presentation/storage_screen.dart';

class _NavItem {
  const _NavItem(this.title, this.icon, this.page);
  final String title;
  final IconData icon;
  final int page;
}

/// Adaptive shell: desktop sidebar (NavigationRail) on wide layouts,
/// mobile bottom navigation otherwise. A persistent mini-player sits above
/// the navigation.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _page = 0;
  bool _dragging = false;

  static const _items = [
    _NavItem('Home', Icons.home_outlined, 0),
    _NavItem('Library', Icons.library_music_outlined, 1),
    _NavItem('Albums', Icons.album_outlined, 2),
    _NavItem('Artists', Icons.person_outline, 3),
    _NavItem('Genres', Icons.local_offer_outlined, 4),
    _NavItem('Playlists', Icons.playlist_play_outlined, 5),
    _NavItem('Favorites', Icons.favorite_border, 6),
    _NavItem('Search', Icons.search_outlined, 7),
    _NavItem('Downloads', Icons.download_outlined, 8),
    _NavItem('Storage', Icons.storage_outlined, 9),
    _NavItem('History', Icons.history_outlined, 10),
    _NavItem('Settings', Icons.settings_outlined, 11),
  ];

  Widget get _body {
    switch (_page) {
      case 0:
        return _HomePage(onNavigate: (page) => setState(() => _page = page));
      case 1:
        return const LibraryScreen();
      case 2:
        return const AlbumsScreen();
      case 3:
        return const ArtistsScreen();
      case 4:
        return const GenresScreen();
      case 5:
        return const PlaylistsScreen();
      case 6:
        return const FavoritesScreen();
      case 7:
        return const SearchScreen();
      case 8:
        return const DownloadsScreen();
      case 9:
        return const StorageScreen();
      case 10:
        return const HistoryScreen();
      case 11:
        return const SettingsScreen();
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
          selectedIndex: _page,
          onDestinationSelected: (i) => setState(() => _page = i),
          labelType: NavigationRailLabelType.all,
          destinations: [for (final item in _items) NavigationRailDestination(icon: Icon(item.icon), label: Text(item.title))],
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
          selectedIndex: _page,
          onDestinationSelected: (i) => setState(() => _page = i),
          destinations: [
            for (final item in _items)
              NavigationDestination(icon: Icon(item.icon), label: item.title),
          ],
        ),
      ],
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({required this.onNavigate});

  final void Function(int page) onNavigate;

  @override
  Widget build(BuildContext context) {
    const tiles = [
      (Icons.library_music, 'Library', 1),
      (Icons.album, 'Albums', 2),
      (Icons.person, 'Artists', 3),
      (Icons.local_offer, 'Genres', 4),
      (Icons.playlist_play, 'Playlists', 5),
      (Icons.favorite, 'Favorites', 6),
      (Icons.search, 'Search', 7),
      (Icons.download, 'Downloads', 8),
      (Icons.storage, 'Storage', 9),
      (Icons.history, 'History', 10),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: GridView.count(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        padding: const EdgeInsets.all(16),
        children: [
          for (final (icon, label, page) in tiles)
            Card(
              child: InkWell(
                onTap: () => onNavigate(page),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [Icon(icon, size: 36), const SizedBox(height: 8), Text(label)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

