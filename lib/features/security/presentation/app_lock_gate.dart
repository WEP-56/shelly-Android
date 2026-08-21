import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../core/security/app_lock_authenticator.dart';
import '../../../core/security/app_lock_settings.dart';
import '../application/app_lock_controller.dart';

/// Full-screen cover installed from `MaterialApp.builder`, so it sits above
/// every pushed route (terminal, sheets) without tearing them down: the child
/// stays in the tree, which keeps the SSH session and transfers alive.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _promptPending = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _maybePrompt();
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _maybePrompt();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() => _maybePrompt();

  /// Shows the system prompt once per lock episode. A denial stops the
  /// auto-prompt, so cancelling does not loop; the user taps 重试 instead.
  void _maybePrompt() {
    final controller = widget.controller;
    if (_promptPending || !_shouldPrompt(controller)) return;
    _promptPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _promptPending = false;
        return;
      }
      if (!_shouldPrompt(widget.controller)) {
        _promptPending = false;
        return;
      }
      await widget.controller.unlockApp();
      _promptPending = false;
    });
  }

  bool _shouldPrompt(AppLockController controller) =>
      controller.isLocked &&
      !controller.isAuthenticating &&
      controller.lastDenial == null;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final locked = widget.controller.isLocked;
        return Stack(
          children: [
            // Animations are paused and semantics hidden while covered, so the
            // locked screen is not readable by assistive tech.
            TickerMode(
              enabled: !locked,
              child: ExcludeSemantics(excluding: locked, child: widget.child),
            ),
            if (locked)
              Positioned.fill(
                child: _AppLockScreen(controller: widget.controller),
              ),
          ],
        );
      },
    );
  }
}

class _AppLockScreen extends StatefulWidget {
  const _AppLockScreen({required this.controller});

  final AppLockController controller;

  @override
  State<_AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<_AppLockScreen> {
  bool _confirmDisable = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final theme = Theme.of(context);
    final controller = widget.controller;
    final denial = controller.lastDenial;
    final busy = controller.isAuthenticating;

    return Material(
      color: colors.page,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: colors.surface2,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 28,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Shelly 已锁定',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    busy ? '请在系统提示中完成验证' : '验证身份后继续使用',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurface2,
                    ),
                  ),
                  if (denial != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: colors.line),
                      ),
                      child: Text(
                        denial.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: busy || (denial != null && !denial.canRetry)
                          ? null
                          : () => controller.unlockApp(),
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fingerprint_rounded, size: 18),
                      label: Text(denial == null ? '验证身份' : '重试'),
                    ),
                  ),
                  if (denial != null && denial.canDisable) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: busy ? null : _handleDisable,
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colors.line2),
                          foregroundColor: colors.onSurface2,
                        ),
                        child: Text(_confirmDisable ? '确认关闭应用锁' : '关闭应用锁并继续'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _confirmDisable
                          ? '关闭后所有受保护的界面都不再验证，可在设置中重新开启。'
                          : '仅当此设备无法完成系统验证时使用。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurface3,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleDisable() {
    if (!_confirmDisable) {
      setState(() => _confirmDisable = true);
      return;
    }
    widget.controller.disableLock();
  }
}

/// Runs the gate for an in-app scope and reports a failure through the nearest
/// [ScaffoldMessenger]. Returns whether the caller may continue.
Future<bool> ensureAppLockUnlocked(
  BuildContext context,
  AppLockController controller,
  AppLockScope scope,
) async {
  final result = await controller.requestScope(scope);
  if (result is AppLockGranted) return true;
  final denial = result as AppLockDenied;
  if (!context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('${scope.label}：${denial.message}'),
      action: denial.canDisable
          ? SnackBarAction(
              label: '关闭应用锁',
              onPressed: () => controller.disableLock(),
            )
          : null,
    ),
  );
  return false;
}
