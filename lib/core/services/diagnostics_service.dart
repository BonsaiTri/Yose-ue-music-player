
import 'package:device_info_plus/device_info_plus.dart';

import 'package:music_player/core/logging/app_logger.dart';
import 'package:music_player/core/platform/platform_info.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/core/services/file_service.dart';

/// Collects application state and exports sanitized diagnostic reports.
class DiagnosticsService {
  DiagnosticsService({required this.files, required this.db});

  final FileService files;
  final AppDatabase db;

  Future<String> buildReport({String? appVersion}) async {
    final buffer = StringBuffer();
    buffer.writeln(AppLogger.buildReport(appVersion: appVersion, platform: PlatformInfo.name));
    buffer.writeln('## Environment');
    buffer.writeln('- Platform: ${PlatformInfo.name} (${PlatformInfo.arch})');
    try {
      final info = await DeviceInfoPlugin().deviceInfo;
      if (info is AndroidDeviceInfo) {
        buffer.writeln('- Device: ${info.brand} ${info.model} (Android ${info.version.release})');
      }
    } catch (e) {
      buffer.writeln('- Device info unavailable: $e');
    }
    buffer.writeln('- Storage root: ${files.root}');

    buffer.writeln('\n## Database health');
    try {
      final row = await db.customSelect('PRAGMA quick_check').getSingle();
      buffer.writeln('- quick_check: ${row.read<String>('quick_check')}');
      final pageRow = await db.customSelect('PRAGMA page_count').getSingle();
      buffer.writeln('- page_count: ${pageRow.read<int>('page_count')}');
    } catch (e) {
      buffer.writeln('- Database check failed: $e');
    }

    buffer.writeln('\n## Storage usage');
    buffer.writeln('- Downloads: ${(await files.directorySize(files.downloadsDir) / 1048576).toStringAsFixed(1)} MB');
    buffer.writeln('- Artwork: ${(await files.directorySize(files.artworkDir) / 1048576).toStringAsFixed(1)} MB');
    buffer.writeln('- Cache: ${(await files.directorySize(files.cacheDir) / 1048576).toStringAsFixed(1)} MB');
    return buffer.toString();
  }

  Future<String> export() async {
    final file = await AppLogger.writeReport(files.root, appVersion: '0.1.0', platform: PlatformInfo.name);
    return file.path;
  }
}
