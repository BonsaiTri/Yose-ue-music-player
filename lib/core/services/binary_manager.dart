import 'dart:io';

import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/platform/platform_info.dart';

/// Binary status reported by [BinaryManager].
class BinaryStatus {
  const BinaryStatus({required this.os, required this.arch, this.available, this.version, this.notes});
  final String os;
  final String arch;
  final bool? available;
  final String? version;
  final String? notes;
}

/// Detects the host OS/arch, selects bundled native dependencies, extracts
/// them to the data directory, validates executables and reports status.
///
/// Desktop only. Android uses a separately validated strategy (see
/// Milestone 4); this manager must never spawn desktop-style subprocesses
/// on mobile.
class BinaryManager {
  BinaryManager({required this.binDir, required this.assetsRoot});

  /// Extracted native dependency directory under the app data root.
  final String binDir;
  /// Root of bundled platform assets (desktop builds).
  final String assetsRoot;

  bool get isSupported => PlatformInfo.isDesktop;

  Future<List<BinaryStatus>> ensureDependencies() async {
    if (!isSupported) {
      return [BinaryStatus(os: PlatformInfo.name, arch: 'arm64', notes: 'Android strategy not yet wired')];
    }
    final os = PlatformInfo.name.toLowerCase();
    final arch = PlatformInfo.arch;
    final assetDir = '$assetsRoot/binaries/$os/$arch';
    final status = await _validateAndExtract(assetDir, os, arch);
    AppLogger.info('Binary check: $status', tag: 'binary');
    return [status];
  }

  Future<BinaryStatus> _validateAndExtract(String assetDir, String os, String arch) async {
    if (!Directory(assetDir).existsSync()) {
      return BinaryStatus(os: os, arch: arch, available: false, notes: 'No bundled assets for this platform');
    }
    final extractDir = '$binDir/$os/$arch';
    Directory(extractDir).createSync(recursive: true);
    var ok = true;
    for (final entity in Directory(assetDir).listSync()) {
      if (entity is! File) continue;
      final target = '$extractDir/${entity.path.split(Platform.pathSeparator).last}';
      if (!File(target).existsSync()) {
        await entity.copy(target);
      }
      if (PlatformInfo.isLinux || PlatformInfo.isMacOS) {
        try {
          Process.runSync('chmod', ['+x', target]);
        } catch (e) {
          AppLogger.warning('chmod failed for $target: $e', tag: 'binary');
          ok = false;
        }
      }
    }
    return BinaryStatus(os: os, arch: arch, available: ok, notes: ok ? 'ready' : 'validation failed');
  }
}
