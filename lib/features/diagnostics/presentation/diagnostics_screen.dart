import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _generating = false;
  bool _testingYouTube = false;
  String? _lastReportPath;
  String? _reportPreview;
  String? _youtubeResult;

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(appDepsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      floatingActionButton: FloatingActionButton(
        onPressed: _generating
            ? null
            : () async {
                setState(() => _generating = true);
                try {
                  final path = await deps.diagnostics.export();
                  final content = File(path).existsSync() ? await File(path).readAsString() : null;
                  if (mounted) {
                    setState(() {
                      _lastReportPath = path;
                      _reportPreview = content;
                    });
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report failed: $e')));
                  }
                } finally {
                  if (mounted) setState(() => _generating = false);
                }
              },
        child: _generating
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.file_download_outlined),
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Export diagnostic report'),
            subtitle: Text(
              'Collects environment, database health, storage usage, recent events and binary status into a redacted report.',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_lastReportPath != null)
            ListTile(title: const Text('Last report'), subtitle: Text(_lastReportPath!)),
          if (_reportPreview != null)
            Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _reportPreview!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ListTile(
            title: const Text('Test YouTube connection'),
            subtitle: Text(_youtubeResult ??
                'Resolves a well-known video through the same path downloads use. Useful when a queue attempt fails.'),
            trailing: _testingYouTube
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : const Icon(Icons.play_circle_outline),
            onTap: _testingYouTube
                ? null
                : () async {
                    setState(() => _testingYouTube = true);
                    _youtubeResult = null;
                    final deps = ref.watch(appDepsProvider);
                    try {
                      // First run may extract the bundled yt-dlp runtime
                      // (Android) or download the pinned desktop binary —
                      // that is expected and only happens once.
                      final yt = deps.ytDlp;
                      await yt.ensureReady();
                      final entries = await yt
                          .list('https://www.youtube.com/watch?v=jNQXAC9IVRw');
                      if (mounted) {
                        final first = entries.first;
                        setState(() => _youtubeResult =
                            'OK — yt-dlp resolved "${first.title}"'
                            '${first.channel != null ? ' by ${first.channel}' : ''}.');
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() => _youtubeResult = 'Failed: $e');
                      }
                    } finally {
                      if (mounted) setState(() => _testingYouTube = false);
                    }
                  },
          ),
          const ListTile(
            title: Text('Log storage'),
            subtitle: Text('Recent app events are kept in bounded memory and included in reports. Sensitive paths and tokens are redacted.'),
          ),
        ],
      ),
    );
  }
}
