import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../core/security/app_lock_authenticator.dart';
import '../../../core/security/app_lock_settings.dart';
import '../../../ui/settings_tiles.dart';
import '../application/app_lock_controller.dart';

/// Opens the app lock editor: which surfaces are guarded, and how long the app
/// may stay in the background before they lock again.
Future<void> showAppLockSheet(
  BuildContext context, {
  required AppLockController controller,
  required AppLockSettings lock,
  required ValueChanged<AppLockSettings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.76,
      child: _AppLockSheet(
        controller: controller,
        lock: lock,
        onChanged: onChanged,
      ),
    ),
  );
}

/// One-line summary for the settings row that opens the sheet.
String describeAppLock(AppLockSettings lock) {
  if (!lock.enabled) return '关闭';
  if (lock.scopes.isEmpty) return '已开启，但未选择任何界面';
  return '${lock.scopes.length} 个界面 · ${describeAppLockGrace(lock.grace)}后重新锁定';
}

class _AppLockSheet extends StatefulWidget {
  const _AppLockSheet({
    required this.controller,
    required this.lock,
    required this.onChanged,
  });

  final AppLockController controller;
  final AppLockSettings lock;
  final ValueChanged<AppLockSettings> onChanged;

  @override
  State<_AppLockSheet> createState() => _AppLockSheetState();
}

class _AppLockSheetState extends State<_AppLockSheet> {
  late AppLockSettings _lock = widget.lock;
  AppLockAvailability? _availability;
  bool _probing = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final availability = await widget.controller.probe();
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _probing = false;
    });
  }

  void _update(AppLockSettings next) {
    setState(() => _lock = next);
    widget.onChanged(next);
  }

  /// Turning the lock on requires a successful authentication first: it proves
  /// this device can actually let the user back in. Turning it off does not, so
  /// a broken sensor can never trap someone out of their own hosts.
  Future<void> _setEnabled(bool value) async {
    if (!value) {
      setState(() => _error = null);
      _update(_lock.copyWith(enabled: false));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.controller.verifyForSetup();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case AppLockGranted():
        _update(_lock.copyWith(enabled: true));
      case AppLockDenied(:final message):
        setState(() => _error = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final availability = _availability;
    final subtitle = _probing
        ? '正在检查设备验证能力…'
        : availability?.summary ?? '无法确定设备验证能力';

    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.lock_outline_rounded,
            title: '应用锁',
            subtitle: subtitle,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              children: [
                SettingsSection(
                  label: '开关',
                  children: [
                    SettingsRow(
                      icon: Icons.security_rounded,
                      label: '启用应用锁',
                      hint: '使用系统生物识别或设备密码验证',
                      trailing: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Switch(
                              value: _lock.enabled,
                              onChanged:
                                  (availability?.canAuthenticate ?? false) ||
                                      _lock.enabled
                                  ? _setEnabled
                                  : null,
                            ),
                    ),
                  ],
                ),
                if (_error != null)
                  _Notice(
                    text: _error!,
                    color: Theme.of(context).colorScheme.error,
                  ),
                if (!_probing && !(availability?.canAuthenticate ?? false))
                  _Notice(
                    text:
                        '${availability?.detail ?? '设备无法完成系统验证'}。'
                        '请先在系统设置中添加锁屏密码或生物识别。',
                    color: colors.onSurface2,
                  ),
                if (_lock.enabled && _lock.isIdle)
                  _Notice(
                    text: '应用锁已开启但没有选择任何界面，当前不会验证任何操作。',
                    color: Theme.of(context).colorScheme.error,
                  ),
                SettingsSection(
                  label: '锁定范围',
                  children: [
                    for (final scope in allAppLockScopes)
                      SettingsRow(
                        icon: _scopeIcon(scope),
                        label: scope.label,
                        hint: scope.description,
                        trailing: Switch(
                          value: _lock.scopes.contains(scope),
                          onChanged: _lock.enabled
                              ? (value) =>
                                    _update(_lock.withScope(scope, value))
                              : null,
                        ),
                      ),
                  ],
                ),
                SettingsSection(
                  label: '自动重新锁定',
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '离开应用超过这段时间后重新验证',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurface2,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final choice in AppLockSettings.graceChoices)
                                ChoiceChip(
                                  label: Text(describeAppLockGrace(choice)),
                                  labelStyle: const TextStyle(fontSize: 12),
                                  selected: _lock.grace == choice,
                                  onSelected: _lock.enabled
                                      ? (_) => _update(
                                          _lock.copyWith(grace: choice),
                                        )
                                      : null,
                                ),
                            ],
                          ),
                          if (!AppLockSettings.graceChoices.contains(
                            _lock.grace,
                          )) ...[
                            const SizedBox(height: 10),
                            Text(
                              '当前值：${describeAppLockGrace(_lock.grace)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurface3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Text(
                    '关闭应用锁不需要验证，避免传感器损坏后无法进入应用；'
                    '应用锁不会加密数据，密钥和 API Key 始终保存在系统安全存储中。',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: colors.onSurface3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _scopeIcon(AppLockScope scope) => switch (scope) {
    AppLockScope.appStartup => Icons.phonelink_lock_rounded,
    AppLockScope.agentPanel => Icons.smart_toy_outlined,
    AppLockScope.providerKey => Icons.vpn_key_outlined,
    AppLockScope.hostCredentials => Icons.password_rounded,
  };
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, height: 1.5, color: color),
      ),
    );
  }
}
