import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart' as log;

import 'package:music_player/core/constants/app_constants.dart';

/// Centralized application logging.
///
/// Log records are kept in memory (bounded) so diagnostics can export a
/// sanitized report without retaining unbounded history.
class AppLogger {
  AppLogger._();

  static final _logger = log.Logger(
    printer: log.PrettyPrinter(lineLength: 160),
  );

  /// Bounded in-memory ring of recent diagnostic entries.
  static final List<String> _recent = <String>[];
  static const int _maxEntries = 2000;

  /// True when a log line must not be exported to user-visible reports.
  static const Set<String> _sensitiveFragments = {
    'secret', 'password', 'token', 'credential', 'auth',
  };

  static void info(String message, {String tag = 'app'}) => _log('I', tag, message);
  static void warning(String message, {String tag = 'app'}) => _log('W', tag, message);
  static void error(String message, {String tag = 'app', Object? error, StackTrace? stack}) {
    _log('E', tag, '$message${error == null ? '' : ' | $error'}');
    if (stack != null) {
      for (final line in stack.toString().split('\n').take(8)) {
        _recent.add('  $line');
      }
      _trim();
    }
  }

  static void _log(String level, String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} [$level] [$tag] $message';
    _recent.add(line);
    _trim();
    _logger.d(line);
  }

  static void _trim() {
    while (_recent.length > _maxEntries) {
      _recent.removeAt(0);
    }
  }

  /// Builds a diagnostic report with sensitive fragments redacted.
  static String buildReport({String? appVersion, String? platform}) {
    final buffer = StringBuffer()
      ..writeln('# $AppConstants.appName diagnostic report')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Version: ${appVersion ?? 'dev'} | Platform: ${platform ?? 'unknown'}')
      ..writeln()
      ..writeln('## Recent log entries');
    for (final line in _recent) {
      buffer.writeln(_redact(line));
    }
    return buffer.toString();
  }

  static String _redact(String line) {
    var out = line;
    for (final fragment in _sensitiveFragments) {
      final regex = RegExp('($fragment[=:" ]+)([^ "\\n]+)', caseSensitive: false);
      out = out.replaceAll(regex, r'$1[REDACTED]');
    }
    return out;
  }

  /// Writes the current diagnostic report to the logs directory.
  static Future<File> writeReport(String root, {String? appVersion, String? platform}) async {
    final logsDir = '$root/${AppConstants.dirLogs}';
    Directory(logsDir).createSync(recursive: true);
    final stamp = DateTime.now().toUtc().toString().replaceAll(RegExp(r':|\.| '), '_');
    final file = File('$logsDir/report_$stamp.txt');
    await file.writeAsString(buildReport(appVersion: appVersion, platform: platform));
    return file;
  }

  /// Encodes arbitrary data for safe logging (single line).
  static String safeJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return '$value';
    }
  }
}
