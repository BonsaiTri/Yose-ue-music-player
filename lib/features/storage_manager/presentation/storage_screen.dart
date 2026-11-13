import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';

/// Storage dashboard: usage per category, temp cleanup, storage location.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  Map<String, int> _sizes = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = ref.read(appDepsProvider).files;
    final result = <String, int>{
      'Music': await files.directorySize(files.musicDir),
      'Downloads': await files.directorySize(files.downloadsDir),
      'Artwork': await files.directorySize(files.artworkDir),
      'Cache': await files.directorySize(files.cacheDir),
      'Backups': await files.directorySize(files.backupsDir),
      'Database': await files.directorySize(files.databaseDir, recursive: false),
    };
    if (mounted) setState(() => _sizes = result);
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.read(appDepsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final removed = await deps.files.cleanupAbandonedTemps(olderThan: Duration.zero);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Removed $removed abandoned temp file(s)')));
          }
          await _load();
        },
        child: const Icon(Icons.cleaning_services),
        tooltip: 'Clean abandoned temp files',
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Location: ${deps.root}', style: Theme.of(context).textTheme.bodySmall),
          ),
          for (final entry in _sizes.entries)
            ListTile(
              title: Text(entry.key),
              trailing: Text(_fmt(entry.value)),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'External drives: tracks on disconnected volumes are marked '
              'Offline, never deleted. Rescan from Settings when a drive reconnects.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
