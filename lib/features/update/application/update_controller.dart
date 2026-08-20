import 'package:flutter/foundation.dart';

import '../data/github_release_client.dart';
import '../data/installed_version.dart';
import '../domain/app_release.dart';
import '../domain/app_version.dart';
import '../domain/update_failure.dart';

enum UpdateCheckStatus {
  /// Nothing has been checked yet in this app run.
  idle,
  checking,
  upToDate,
  updateAvailable,
  failed,
}

/// Manual update check for the settings page.
///
/// There is no background polling and no automatic check on launch: the user
/// taps the row, one request goes out, and the result stays until they check
/// again.
class UpdateController extends ChangeNotifier {
  UpdateController({
    GithubReleaseClient? client,
    Future<InstalledVersion> Function()? versionReader,
  }) : _client = client ?? GithubReleaseClient(),
       _readVersion = versionReader ?? readInstalledVersion;

  final GithubReleaseClient _client;
  final Future<InstalledVersion> Function() _readVersion;

  UpdateCheckStatus _status = UpdateCheckStatus.idle;
  InstalledVersion? _installed;
  AppRelease? _latest;
  String? _message;
  String? _detail;
  bool _canRetry = false;
  bool _disposed = false;

  UpdateCheckStatus get status => _status;

  /// Null until the package version has been read from the platform.
  InstalledVersion? get installed => _installed;

  /// Latest release from the last successful check, new or not.
  AppRelease? get latest => _latest;

  /// User-facing failure message; null unless [status] is
  /// [UpdateCheckStatus.failed].
  String? get message => _message;
  String? get detail => _detail;
  bool get canRetry => _canRetry;

  Uri get releasesPageUrl => _client.releasesPageUrl;

  /// Reads the installed version so the settings row can show it before any
  /// network call. Failing here only leaves the version line blank.
  Future<void> loadInstalledVersion() async {
    if (_installed != null) return;
    final version = await _readVersion();
    _installed = version;
    _notify();
  }

  Future<void> check() async {
    if (_status == UpdateCheckStatus.checking) return;
    _status = UpdateCheckStatus.checking;
    _message = null;
    _detail = null;
    _canRetry = false;
    _notify();

    try {
      await loadInstalledVersion();
      final installed = _installed;
      final current = installed == null
          ? null
          : AppVersion.tryParse(installed.versionName);
      if (current == null) {
        throw UpdateCheckException(
          kind: UpdateFailureKind.unrecognisedVersion,
          message: '无法识别当前应用版本，暂时不能比较更新。',
          detail: 'installed version "${installed?.versionName}"',
        );
      }

      final release = await _client.fetchLatestRelease();
      final remote = AppVersion.tryParse(release.tag);
      if (remote == null) {
        throw UpdateCheckException(
          kind: UpdateFailureKind.unrecognisedVersion,
          message: '最新发布的 tag "${release.tag}" 不是可比较的版本号。',
          detail: 'unparsable tag',
        );
      }
      _latest = release;
      _status = remote.isNewerThan(current)
          ? UpdateCheckStatus.updateAvailable
          : UpdateCheckStatus.upToDate;
    } on UpdateCheckException catch (failure) {
      _status = UpdateCheckStatus.failed;
      _message = failure.message;
      _detail = failure.detail;
      _canRetry = failure.canRetry;
    } on Object catch (error) {
      // Reading the package version goes through a platform channel; a failure
      // there is not an UpdateCheckException but must still not crash settings.
      _status = UpdateCheckStatus.failed;
      _message = '检查更新失败，请稍后重试。';
      _detail = error.toString();
      _canRetry = true;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
