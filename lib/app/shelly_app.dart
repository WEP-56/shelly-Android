import 'dart:async';

import 'package:flutter/material.dart';

import '../core/storage/app_services.dart';
import '../core/storage/settings_repository.dart';
import '../features/home/home_shell.dart';
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

  ThemeMode get _themeMode => switch (_themePreference) {
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
    ThemePreference.system => ThemeMode.system,
  };

  @override
  void initState() {
    super.initState();
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
    if (widget.services == null) unawaited(_services?.close());
    super.dispose();
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
      home: _loading
          ? const _StartupView()
          : _startupError != null
          ? _StartupErrorView(onRetry: _initialize)
          : HomeShell(
              services: _services!,
              themePreference: _themePreference,
              settings: _settings,
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
    unawaited(_persistSettings(value, previous, revision));
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
      if (_settingsRevision == revision) setState(() => _settings = previous);
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
