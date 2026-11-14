import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/app.dart';
import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/constants/app_constants.dart';
import 'package:music_player/core/services/data_mover.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/playlist_settings_history_repository.dart';
import 'package:music_player/features/diagnostics/presentation/diagnostics_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  ThemeMode _themeMode = ThemeMode.system;
  int _maxConcurrent = 3;
  String? _lastBackup;
  bool _busy = false;
  String? _defaultRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(appDepsProvider).settings;
    _themeMode = switch (await settings.get('theme.mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final last = await settings.get('backup.lastPath');
    final maxConcurrent =
        int.tryParse(await settings.get('downloads.maxConcurrent') ?? '') ?? 3;
    final defRoot = await defaultAppRoot();
    if (mounted) {
      setState(() {
        _lastBackup = last;
        _maxConcurrent = [1, 2, 3, 5].contains(maxConcurrent) ? maxConcurrent : 3;
        _defaultRoot = defRoot;
      });
      ref.read(themeModeProvider.notifier).state = _themeMode;
    }
  }

  Future<void> _setMaxConcurrent(int value) async {
    await ref.read(appDepsProvider).settings.set('downloads.maxConcurrent', '$value');
    setState(() => _maxConcurrent = value);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Queue limit saved — applied on next launch.')));
    }
  }

  Future<void> _pickDataLocation() async {
    final deps = ref.read(appDepsProvider);
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || !mounted || path == deps.root) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move library data?'),
        content: Text(
          'All music, artwork, downloads and backups will be copied to:\n\n$path\n\n'
          'The source data is left untouched until the app restarts on the new '
          'location. On Android, folders outside the app storage may need '
          'their permission re-granted after a restart.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Blocking progress dialog; the migration never deletes the source.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Moving data… this can take a while.'),
          ],
        ),
      ),
    );
    String? error;
    try {
      await const DataMover().migrate(
        db: deps.db,
        from: deps.root,
        to: path,
        defaultRoot: (await defaultAppRoot()),
      );
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) Navigator.of(context).pop(); // dismiss progress dialog
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error == null
          ? 'Library moved to $path — relaunch the app to use it.'
          : 'Move failed (original data untouched): $error'),
    ));
  }

  /// Restores the platform default data location by clearing the persisted
  /// choice (the default-root database is what bootstrap probes).
  Future<void> _resetDataLocation() async {
    final def = _defaultRoot;
    final deps = ref.read(appDepsProvider);
    if (def == null || deps.root == def) return;
    try {
      final dbFile = File(p.join(def, AppConstants.dirDatabase, AppConstants.databaseFileName));
      final probe = AppDatabase.withFile(dbFile);
      try {
        await SettingsRepository(probe).delete('storage.root');
      } finally {
        await probe.close();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Default location restored — relaunch the app.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not reset location: $e')));
      }
    }
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    await ref.read(appDepsProvider).settings.set('theme.mode', mode.name);
    ref.read(themeModeProvider.notifier).state = mode;
    setState(() => _themeMode = mode);
  }

  Future<void> _createBackup() async {
    setState(() => _busy = true);
    try {
      final dir = await ref.read(appDepsProvider).backup.createBackup();
      final path = dir.path;
      await ref.read(appDepsProvider).settings.set('backup.lastPath', path);
      await ref.read(appDepsProvider).settings.set('backup.lastCompletedAt', DateTime.now().toIso8601String());
      if (!mounted) return;
      setState(() => _lastBackup = path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup verified and saved: $path')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    setState(() => _busy = true);
    final backup = ref.read(appDepsProvider).backup;
    try {
      final backups = await backup.listBackups();
      if (backups.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No backups available')));
        }
        return;
      }
      final chosen = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Choose backup'),
          content: SizedBox(
            height: 240,
            child: ListView.builder(
              itemCount: backups.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(p.basename(backups[i].path)),
                onTap: () => Navigator.pop(ctx, i),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        ),
      );
      if (chosen == null) return;
      await backup.restoreLatest(backup: backups[chosen]);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Backup restored. Restart the app to load it fully.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(appDepsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('General', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            title: const Text('Appearance'),
            subtitle: Text(switch (_themeMode) {
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
              _ => 'System',
            }),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
              ],
              selected: {_themeMode},
              onSelectionChanged: (s) => _setThemeMode(s.first),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Downloads', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            title: const Text('Max concurrent downloads'),
            subtitle: const Text('Queue limit; applied on next launch'),
            trailing: DropdownButton<int>(
              value: _maxConcurrent,
              items: const [1, 2, 3, 5]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                _setMaxConcurrent(v);
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Storage', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            title: const Text('Data location'),
            subtitle: Text(
              deps.root == _defaultRoot
                  ? '$deps.root  (default)'
                  : '$deps.root  (custom)',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.folder_outlined),
            onTap: _pickDataLocation,
          ),
          if (deps.root != _defaultRoot)
            ListTile(
              title: const Text('Use default location'),
              subtitle: const Text(
                  'Stop using the custom location and return to the app default'),
              trailing: const Icon(Icons.home_work_outlined),
              onTap: _resetDataLocation,
            ),
          ListTile(
            title: const Text('Rescan library files'),
            subtitle: const Text('Re-verify file availability (external drives)'),
            onTap: () async {
              final updated = await deps.tracks.updateAvailabilityForAll();
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Availability updated for $updated track(s)')));
              }
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Backup & Restore', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            title: const Text('Create backup'),
            subtitle: Text(_lastBackup ?? 'No backup yet', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _busy ? null : _createBackup,
          ),
          ListTile(
            title: const Text('Restore from backup'),
            subtitle: const Text('Verify, then restore a verified backup (current DB preserved first)'),
            trailing: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _busy ? null : _restoreBackup,
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Troubleshooting', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            title: const Text('Diagnostics'),
            subtitle: const Text(
                'Export a report, test the YouTube connection, inspect logs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('About', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/logo/logo.jpg',
                  height: 96, width: 96, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(AppConstants.appName,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text('Version ${AppConstants.appVersion} · offline-first',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 16),
          const ListTile(
            title: Text('Application data'),
            subtitle: Text('Resolved per-platform; no absolute paths hardcoded.'),
          ),
        ],
      ),
    );
  }
}
