import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:music_player/app/bootstrap.dart';

/// Loads a stored artwork reference from disk with a safe placeholder.
class ArtworkImage extends ConsumerWidget {
  const ArtworkImage({super.key, required this.artworkId, this.size = 44});

  final String? artworkId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deps = ref.watch(appDepsProvider);
    return _ArtworkLoader(artworkId: artworkId, size: size, artworkService: deps.artwork);
  }
}

class _ArtworkLoader extends StatefulWidget {
  const _ArtworkLoader({required this.artworkId, required this.size, required this.artworkService});
  final String? artworkId;
  final double size;
  final dynamic artworkService;

  @override
  State<_ArtworkLoader> createState() => _ArtworkLoaderState();
}

class _ArtworkLoaderState extends State<_ArtworkLoader> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The mini player and list tiles reuse this widget state when the
  /// underlying track changes — reload when the artwork reference does.
  @override
  void didUpdateWidget(covariant _ArtworkLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkId != widget.artworkId) {
      _path = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.artworkId;
    if (id == null) {
      if (_path != null) setState(() => _path = null);
      return;
    }
    final path = await widget.artworkService.absolutePathFor(id);
    if (!mounted || widget.artworkId != id) return; // stale result
    setState(() => _path = (path != null && File(path).existsSync()) ? path : null);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: _path == null
          ? const Icon(Icons.music_note, size: 28)
          : Image.file(File(_path!), fit: BoxFit.cover),
    );
  }
}
