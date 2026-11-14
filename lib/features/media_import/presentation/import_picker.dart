import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/features/media_import/domain/import_service.dart';

/// Shows an "Import files… / Import folder…" chooser, runs the shared
/// import pipeline and reports the outcome with a snackbar.
///
/// Returns the [ImportResult], or `null` when the user cancelled.
Future<ImportResult?> pickAndImport(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Import music'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('Choose files…'),
            subtitle: const Text('Pick one or more audio files'),
            onTap: () => Navigator.pop(ctx, 'files'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Choose a folder…'),
            subtitle: const Text('Import everything inside, including sub-folders'),
            onTap: () => Navigator.pop(ctx, 'folder'),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return null;

  final paths = <String>[];
  if (choice == 'files') {
    final result =
        await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (result == null) return null;
    paths.addAll(result.files.map((f) => f.path).where((p) => p != null).cast<String>());
  } else {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return null;
    paths.add(dir);
  }
  if (paths.isEmpty) return null;

  try {
    final importResult =
        await ref.read(appDepsProvider).importer.importPaths(paths);
    messenger.showSnackBar(SnackBar(
      content: Text(
          'Imported ${importResult.added} track(s)'
          '${importResult.duplicates > 0 ? ', skipped ${importResult.duplicates} duplicate(s)' : ''}'
          '${importResult.errors > 0 ? ', ${importResult.errors} error(s)' : ''}.'),
    ));
    return importResult;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    return null;
  }
}
