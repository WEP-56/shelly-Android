import 'dart:async';

import 'package:flutter/material.dart';

import '../core/security/app_lock_settings.dart';
import '../core/storage/app_services.dart';
import '../core/storage/settings_repository.dart';
import '../core/system/wakelock_coordinator.dart';
import '../features/home/home_shell.dart';
import '../features/security/application/app_lock_controller.dart';
import '../features/security/presentation/app_lock_gate.dart';
import 'app_theme.dart';
import 'models.dart';

class ShellyApp extends StatefulWidget {
  const ShellyApp({super.key, this.services});

  final AppServices? services;

  @override
  State<ShellyApp> createState() => _ShellyAppState();
}

class _ShellyAppState extends State<ShellyApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  ThemePreference _themePreference = ThemePreference.system;
  AppSettings _settings = const AppSettings();
  AppServices? _services;
  Object? _startupError;
  bool _loading = true;
  int _settingsRevision = 0;
  int _themeRevision = 0;

  /// Created in [initState], before `MaterialApp` mounts, so it registers as a
  /// lifecycle and pop-route observer ahead of `WidgetsApp` and therefore sees
  /// the Android back button first while the app is locked.
  late final AppLockController _lock;

  ThemeMode get _themeMode => switch (_themePreference) {
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
    ThemePreference.system => ThemeMode.system,
  };

  @override
  void initState() {
    super.initState();
    _lock = AppLockController(onSettingsChanged: _lockChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _startupError = null;
    });
    AppServices? services;
    try {
      services = widget.services ?? await AppServices.open();
      final settings = await services.settings.loadSettings();
      final theme = await services.settings.loadTheme();
      if (!mounted) {
        if (widget.services == null) await services.close();
        return;
      }
      setState(() {
        _services = services;
        _settings = settings;
        _themePreference = theme;
        _loading = false;
      });
      // First apply: a cold start is locked whenever the startup scope is on.
      _lock.applySettings(settings.lock);
      _syncGlobalWakeLock();
    } on Object catch (error) {
      if (widget.services == null && services != null) {
        await services.close();
      }
      if (!mounted) return;
      setState(() {
        _startupError = error;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    WakelockCoordinator.instance.release(this);
    _lock.dispose();
    if (widget.services == null) unawaited(_services?.close());
    super.dispose();
  }

  /// Claims the app-wide screen wakelock on behalf of the global setting.
  ///
  /// The terminal page holds its own token, so turning this off does not fight
  /// the per-terminal setting.
  void _syncGlobalWakeLock() {
    WakelockCoordinator.instance.setHeld(this, _settings.globalWakeLock);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shelly',
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: ShellyTheme.light(),
      darkTheme: ShellyTheme.dark(),
      themeMode: _themeMode,
      // The gate goes here rather than around `home`, so it also covers pushed
      // routes such as the terminal without unmounting them.
      builder: (context, child) =>
          AppLockGate(controller: _lock, child: child ?? const SizedBox()),
      home: _loading
          ? const _StartupView()
          : _startupError != null
          ? _StartupErrorView(onRetry: _initialize)
          : HomeShell(
              services: _services!,
              themePreference: _themePreference,
              settings: _settings,
              appLock: _lock,
              onThemeChanged: _themeChanged,
              onSettingsChanged: _settingsChanged,
            ),
    );
  }

  void _themeChanged(ThemePreference value) {
    final previous = _themePreference;
    final revision = ++_themeRevision;
    setState(() => _themePreference = value);
    unawaited(_persistTheme(value, previous, revision));
  }

  void _settingsChanged(AppSettings value) {
    final previous = _settings;
    final revision = ++_settingsRevision;
    setState(() => _settings = value);
    _lock.applySettings(value.lock);
    _syncGlobalWakeLock();
    unawaited(_persistSettings(value, previous, revision));
  }

  /// The lock controller changed its own settings (the only case today is
  /// disabling the lock after an unrecoverable authentication failure).
  Future<void> _lockChanged(AppLockSettings lock) async {
    final value = _settings.copyWith(lock: lock);
    final previous = _settings;
    final revision = ++_settingsRevision;
    setState(() => _settings = value);
    await _persistSettings(value, previous, revision);
  }

  Future<void> _persistTheme(
    ThemePreference value,
    ThemePreference previous,
    int revision,
  ) async {
    try {
      await _services!.settings.saveTheme(value);
    } on SettingsRepositoryException catch (error) {
      if (!mounted) return;
      if (_themeRevision == revision) {
        setState(() => _themePreference = previous);
      }
      _message(error.message);
    }
  }

  Future<void> _persistSettings(
    AppSettings value,
    AppSettings previous,
    int revision,
  ) async {
    try {
      await _services!.settings.saveSettings(value);
    } on SettingsRepositoryException catch (error) {
      if (!mounted) return;
      if (_settingsRevision == revision) {
        setState(() => _settings = previous);
        _lock.applySettings(previous.lock);
        _syncGlobalWakeLock();
      }
      _message(error.message);
    }
  }

  void _message(String message) {
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StartupView extends StatelessWidget {
  const _StartupView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _StartupErrorView extends StatelessWidget {
  const _StartupErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storage_rounded, size: 32),
              const SizedBox(height: 12),
              const Text('无法读取本地数据'),
              const SizedBox(height: 6),
              Text(
                '请重试；如果问题持续，请重启应用后再次尝试。',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.shelly.onSurface3),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
