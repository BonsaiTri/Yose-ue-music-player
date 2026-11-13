import 'dart:io';

/// Runtime platform capabilities. Centralizes platform-specific branching so
/// feature code stays portable.
class PlatformInfo {
  PlatformInfo._();

  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isWindows => Platform.isWindows;
  static bool get isLinux => Platform.isLinux;

  static bool get isDesktop => isMacOS || isWindows || isLinux;
  static bool get isMobile => isAndroid || isIOS;

  /// Human-readable OS name (used in diagnostics).
  static String get name => switch (Platform.operatingSystem) {
        'android' => 'Android',
        'ios' => 'iOS',
        'macos' => 'macOS',
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => Platform.operatingSystem,
      };

  /// CPU architecture used for binary selection.
  static String get arch {
    // Dart's ProcessInformation is not used here on purpose: the native
    // library reports the architecture we need for bundled dependencies.
    final env = Platform.environment;
    final arch = env['PROCESSOR_ARCHITECTURE'] ?? env['ARCH'] ?? '';
    if (arch.contains('ARM64')) return 'arm64';
    if (arch.contains('AMD64') || arch == 'x86_64') return 'x64';
    return 'x64';
  }
}
