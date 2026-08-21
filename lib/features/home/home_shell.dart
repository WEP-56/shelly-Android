import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/storage/app_services.dart';
import '../../features/hosts/application/host_controller.dart';
import '../../features/hosts/data/host_repository.dart';
import '../../ui/shelly_icon_button.dart';
import '../security/application/app_lock_controller.dart';
import '../servers/server_list_view.dart';
import '../settings/settings_view.dart';
import '../terminal/terminal_screen.dart';

enum HomeTab { servers, settings }

class HomeShell extends StatefulWidget {
  const HomeShell({
    required this.services,
    required this.themePreference,
    required this.settings,
    required this.appLock,
    required this.onThemeChanged,
    required this.onSettingsChanged,
    super.key,
  });

  final AppServices services;
  final ThemePreference themePreference;
  final AppSettings settings;
  final AppLockController appLock;
  final ValueChanged<ThemePreference> onThemeChanged;
  final ValueChanged<AppSettings> onSettingsChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  HomeTab _tab = HomeTab.servers;
  late final HostController _hosts = HostController(widget.services.hosts);

  @override
  void initState() {
    super.initState();
    unawaited(_hosts.load());
  }

  @override
  void dispose() {
    _hosts.dispose();
    super.dispose();
  }

  void _openTerminal(HostProfile server) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (context, animation, secondaryAnimation) {
          return TerminalScreen(
            server: server,
            connectionFactory: widget.services.sshConnections,
            keepAlive: widget.settings.keepAlive,
            autoReconnect: widget.settings.autoReconnect,
            terminalWakeLock: widget.settings.terminalWakeLock,
            fontSize: widget.settings.fontSize,
            cursorBlink: widget.settings.cursorBlink,
            extraKeys: widget.settings.extraKeys,
            snippets: widget.services.snippets,
            history: widget.services.history,
            agentSettings: widget.services.agentSettings,
            agentSessions: widget.services.agentSessions,
            appLock: widget.appLock,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: const Cubic(0.22, 0.9, 0.3, 1),
            reverseCurve: Curves.easeIn,
          );
          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.025),
                end: Offset.zero,
              ).animate(curve),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<String?> _saveServer(HostSaveRequest request) async {
    try {
      await _hosts.save(request);
      return null;
    } on HostRepositoryException catch (error) {
      return error.message;
    }
  }

  void _deleteServer(HostProfile server) {
    unawaited(_persistDelete(server));
  }

  Future<void> _persistDelete(HostProfile server) async {
    try {
      await _hosts.delete(server);
      if (!mounted) return;
      _message('已删除');
    } on HostRepositoryException catch (error) {
      if (mounted) _message(error.message);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final brightness = Theme.of(context).brightness;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: 64,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Shelly',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        ShellyIconButton(
                          icon: brightness == Brightness.dark
                              ? Icons.dark_mode_rounded
                              : Icons.light_mode_rounded,
                          tooltip: '主题',
                          onPressed: () => widget.onThemeChanged(
                            brightness == Brightness.dark
                                ? ThemePreference.light
                                : ThemePreference.dark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: const Cubic(0.22, 0.9, 0.3, 1),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.015),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: _tab == HomeTab.servers
                        ? ListenableBuilder(
                            key: const ValueKey('servers'),
                            listenable: _hosts,
                            builder: (context, child) => _buildHostList(),
                          )
                        : ListenableBuilder(
                            key: const ValueKey('settings'),
                            listenable: _hosts,
                            builder: (context, child) => SettingsView(
                              settings: widget.settings,
                              knownHosts: widget.services.knownHosts,
                              agentSettings: widget.services.agentSettings,
                              agentSessions: widget.services.agentSessions,
                              appLock: widget.appLock,
                              hostNames: {
                                for (final host in _hosts.hosts)
                                  host.id: host.name,
                              },
                              themePreference: widget.themePreference,
                              onSettingsChanged: widget.onSettingsChanged,
                              onThemeChanged: widget.onThemeChanged,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            if (_tab == HomeTab.servers)
              ListenableBuilder(
                listenable: _hosts,
                builder: (context, child) => Positioned(
                  right: 20,
                  bottom: 104,
                  child: Material(
                    color: colors.primary,
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap:
                          _hosts.status != HostListStatus.ready ||
                              _hosts.isMutating
                          ? null
                          : () =>
                                showServerEditor(context, onSave: _saveServer),
                      child: SizedBox.square(
                        dimension: 56,
                        child: Icon(
                          Icons.add_rounded,
                          size: 24,
                          color: colors.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: Center(
                child: _Dock(
                  tab: _tab,
                  onChanged: (value) => setState(() => _tab = value),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHostList() {
    return switch (_hosts.status) {
      HostListStatus.loading => const Center(
        child: CircularProgressIndicator(),
      ),
      HostListStatus.failure => _HostLoadError(
        message: _hosts.loadError ?? '读取设备列表失败，请重试。',
        onRetry: _hosts.load,
      ),
      HostListStatus.ready => ServerListView(
        servers: _hosts.hosts,
        onConnect: _openTerminal,
        onSave: _saveServer,
        onDelete: _deleteServer,
        appLock: widget.appLock,
      ),
    };
  }
}

class _HostLoadError extends StatelessWidget {
  const _HostLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 30),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({required this.tab, required this.onChanged});

  final HomeTab tab;
  final ValueChanged<HomeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.elevated,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(26),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DockButton(
              icon: Icons.cloud_rounded,
              tooltip: '服务器',
              selected: tab == HomeTab.servers,
              onTap: () => onChanged(HomeTab.servers),
            ),
            const SizedBox(width: 4),
            _DockButton(
              icon: Icons.settings_rounded,
              tooltip: '设置',
              selected: tab == HomeTab.settings,
              onTap: () => onChanged(HomeTab.settings),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? colors.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 52,
            height: 46,
            child: Icon(icon, size: 21, color: colors.onSurface),
          ),
        ),
      ),
    );
  }
}
