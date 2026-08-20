import 'package:package_info_plus/package_info_plus.dart';

/// Version of the APK that is actually installed, read from the Android package
/// manager rather than a constant, so it always matches what Gradle stamped in
/// from `pubspec.yaml`.
class InstalledVersion {
  const InstalledVersion({
    required this.versionName,
    required this.buildNumber,
  });

  /// Android `versionName`, e.g. `1.0.0`.
  final String versionName;

  /// Android `versionCode` as text; empty when the platform does not report it.
  final String buildNumber;

  String get display =>
      buildNumber.isEmpty ? versionName : '$versionName ($buildNumber)';
}

Future<InstalledVersion> readInstalledVersion() async {
  final info = await PackageInfo.fromPlatform();
  return InstalledVersion(
    versionName: info.version,
    buildNumber: info.buildNumber,
  );
}
