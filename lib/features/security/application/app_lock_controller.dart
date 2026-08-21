import 'package:flutter/widgets.dart';

import '../../../core/security/app_lock_authenticator.dart';
import '../../../core/security/app_lock_settings.dart';

/// Persists a changed [AppLockSettings]; supplied by the app shell, which owns
/// `AppSettings` and the settings repository.
typedef AppLockSettingsSink = Future<void> Function(AppLockSettings settings);

/// Owns the app lock state: whether the full-screen gate is showing, whether a
/// system prompt is on screen, and when the last successful unlock happened.
///
/// It is created before `MaterialApp` so it can register as a
/// [WidgetsBindingObserver] ahead of `WidgetsApp` and therefore see the Android
/// back button first while the app is locked.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({
    required AppLockSettingsSink onSettingsChanged,
    AppLockAuthenticator? authenticator,
  }) : _onSettingsChanged = onSettingsChanged,
       _authenticator = authenticator ?? AppLockAuthenticator() {
    WidgetsBinding.instance.addObserver(this);
  }

  final AppLockSettingsSink _onSettingsChanged;
  final AppLockAuthenticator _authenticator;

  AppLockSettings _settings = const AppLockSettings(enabled: false);
  bool _settingsApplied = false;
  bool _locked = false;
  bool _authenticating = false;
  AppLockDenied? _lastDenial;
  DateTime? _unlockedAt;
  DateTime? _leftAt;

  /// Scopes whose surface is currently on screen. A grace expiry re-locks the
  /// app while one of these is open, even when the startup scope is off.
  final List<AppLockScope> _openSurfaces = [];

  AppLockSettings get settings => _settings;

  /// True while the gate must cover the app.
  bool get isLocked => _locked;

  /// True while a system prompt is on screen.
  bool get isAuthenticating => _authenticating;

  /// Why the last attempt did not pass, or null after a success.
  AppLockDenied? get lastDenial => _lastDenial;

  /// A recent unlock is reused for the in-app scopes for the configured grace,
  /// so unlocking the app and immediately opening the Agent is one prompt, not
  /// two. With a grace of "立即" every scope always prompts.
  bool get _hasFreshUnlock {
    final at = _unlockedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= _settings.grace;
  }

  bool get _hasProtectedSurface => _openSurfaces.any(_settings.protects);

  /// Called by the app shell after settings load and after every change.
  ///
  /// The first call decides the cold-start state: a fresh process is always
  /// locked when the startup scope is on.
  void applySettings(AppLockSettings settings) {
    final firstApply = !_settingsApplied;
    _settingsApplied = true;
    _settings = settings;
    if (firstApply && settings.locksStartup) {
      _locked = true;
      _lastDenial = null;
      _unlockedAt = null;
    } else if (_locked && !settings.locksStartup && !_hasProtectedSurface) {
      // The lock was turned off, or the startup scope was unchecked, while the
      // gate was up.
      _locked = false;
      _lastDenial = null;
    }
    notifyListeners();
  }

  /// Registers that a surface guarded by [scope] is on screen.
  void markSurfaceOpen(AppLockScope scope) => _openSurfaces.add(scope);

  /// Removes one registration added by [markSurfaceOpen].
  void markSurfaceClosed(AppLockScope scope) => _openSurfaces.remove(scope);

  /// Unlocks the gate. Returns the raw result so the gate can show the reason
  /// and the recovery options it allows.
  Future<AppLockAuthResult> unlockApp() async {
    final result = await _authenticate(AppLockScope.appStartup.authReason);
    if (result is AppLockGranted && _locked) {
      _locked = false;
      notifyListeners();
    }
    return result;
  }

  /// Gate for one of the in-app scopes. Granted immediately when the scope is
  /// not protected or a recent unlock still counts.
  Future<AppLockAuthResult> requestScope(AppLockScope scope) async {
    if (!_settings.protects(scope)) return const AppLockGranted();
    if (_hasFreshUnlock) return const AppLockGranted();
    return _authenticate(scope.authReason);
  }

  /// Used by the settings UI before arming the lock, so a device that cannot
  /// authenticate never locks the user out of their own hosts.
  Future<AppLockAuthResult> verifyForSetup() => _authenticate('验证身份以启用应用锁');

  Future<AppLockAvailability> probe() => _authenticator.probe();

  /// Turns the lock off after an unrecoverable failure, and unlocks the gate.
  /// Offered only for [AppLockDenied.canDisable] failures.
  Future<void> disableLock() async {
    final next = _settings.copyWith(enabled: false);
    _settings = next;
    _locked = false;
    _lastDenial = null;
    notifyListeners();
    await _onSettingsChanged(next);
  }

  Future<AppLockAuthResult> _authenticate(String reason) async {
    if (_authenticating) {
      return const AppLockDenied('已有一次验证正在进行，请先完成系统提示');
    }
    _authenticating = true;
    _lastDenial = null;
    notifyListeners();
    AppLockAuthResult result;
    try {
      result = await _authenticator.authenticate(reason: reason);
    } finally {
      _authenticating = false;
    }
    switch (result) {
      case AppLockGranted():
        _unlockedAt = DateTime.now();
        _leftAt = null;
      case AppLockDenied():
        _lastDenial = result;
    }
    notifyListeners();
    return result;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A device-credential fallback opens a system activity, so the app is
    // backgrounded by the prompt itself; ignoring lifecycle changes while a
    // prompt is up keeps that from re-locking mid-authentication.
    if (_authenticating) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _handleResume();
      case AppLifecycleState.inactive:
        // Transient (notification shade, permission dialog); not "away".
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _leftAt ??= DateTime.now();
    }
  }

  void _handleResume() {
    final leftAt = _leftAt;
    _leftAt = null;
    if (leftAt == null) return;
    if (DateTime.now().difference(leftAt) < _settings.grace) return;
    // The unlock credit is dropped either way, so the next protected surface
    // asks again.
    _unlockedAt = null;
    if (_locked) return;
    if (_settings.locksStartup || _hasProtectedSurface) {
      _locked = true;
      _lastDenial = null;
    }
    notifyListeners();
  }

  /// Swallows the Android back button while the gate is up, so back cannot
  /// reveal the screen behind it.
  @override
  Future<bool> didPopRoute() async => _locked;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
