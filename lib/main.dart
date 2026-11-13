import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/app.dart';
import 'package:music_player/app/bootstrap.dart';
import 'package:music_player/core/logging/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProviderContainer? container;
  Object? error;
  try {
    container = await bootstrap();
  } catch (e, st) {
    AppLogger.error('Bootstrap failed: $e', tag: 'bootstrap', error: e, stack: st);
    error = e;
  }
  if (container == null) {
    runApp(_BootstrapFailureScreen(error: error!));
    return;
  }
  runApp(UncontrolledProviderScope(container: container, child: const MusicPlayerApp()));
}

class _BootstrapFailureScreen extends StatefulWidget {
  const _BootstrapFailureScreen({required this.error});
  final Object error;

  @override
  State<_BootstrapFailureScreen> createState() => _BootstrapFailureScreenState();
}

class _BootstrapFailureScreenState extends State<_BootstrapFailureScreen> {
  String? _recovering;
  bool _busy = false;

  Future<void> _recover() async {
    setState(() {
      _busy = true;
      _recovering = 'Quarantining the database and checking backups…';
    });
    String? message;
    Object? error;
    try {
      message = await recoverDatabase();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (message == null) {
      setState(() {
        _busy = false;
        _recovering = 'Nothing to recover — the database file is missing.';
      });
      return;
    }
    setState(() => _recovering = 'Retrying startup…');
    ProviderContainer? container;
    try {
      container = await bootstrap();
    } catch (e, st) {
      AppLogger.error('Bootstrap failed after recovery: $e',
          tag: 'bootstrap', error: e, stack: st);
      error = e;
    }
    if (!mounted) return;
    if (container == null) {
      setState(() {
        _busy = false;
        _recovering =
            'Startup still failed after recovery: $error\nThe quarantined files were kept.';
      });
      return;
    }
    // Success: swap the running app.
    AppLogger.info('Startup succeeded after recovery', tag: 'bootstrap');
    runApp(UncontrolledProviderScope(
        container: container, child: const MusicPlayerApp()));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Failed to start the application.'),
                const SizedBox(height: 12),
                SelectableText('$widget.error'),
                const SizedBox(height: 8),
                Text('Details are available in the Diagnostics screen.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                if (_recovering != null) ...[
                  const SizedBox(height: 16),
                  Text(_recovering!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.restore),
                  label: const Text('Recover database and retry'),
                  onPressed: _busy ? null : _recover,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
