import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:music_player/app/app.dart';
import 'package:music_player/app/bootstrap.dart';

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
    if (mounted) {
      setState(() {
        _lastBackup = last;
        _maxConcurrent = [1, 2, 3, 5].contains(maxConcurrent) ? maxConcurrent : 3;
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
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || !mounted) return;
    await ref.read(appDepsProvider).settings.set('storage.root', path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Data location set to $path — relaunch the app to use it. '
            'Use Backup & Restore to move your library into the new location.'),
      ));
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
            subtitle: Text(deps.root, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.folder_outlined),
            onTap: _pickDataLocation,
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
            child: Text('About', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const ListTile(
            title: Text('Application data'),
            subtitle: Text('Resolved per-platform; no absolute paths hardcoded.'),
          ),
        ],
      ),
    );
  }
}
