import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/ssh/known_host_repository.dart';
import '../../core/ssh/known_hosts_controller.dart';
import '../../core/ssh/ssh_models.dart';
import '../../core/terminal/terminal_input.dart';
import '../../ui/settings_tiles.dart';
import '../agent/data/agent_session_repository.dart';
import '../agent/data/agent_settings_repository.dart';
import '../agent/presentation/agent_settings_section.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.settings,
    required this.knownHosts,
    required this.agentSettings,
    required this.agentSessions,
    required this.hostNames,
    required this.themePreference,
    required this.onSettingsChanged,
    required this.onThemeChanged,
    super.key,
  });

  final AppSettings settings;
  final KnownHostRepository knownHosts;
  final AgentSettingsRepository agentSettings;
  final AgentSessionRepository agentSessions;

  /// Host id → display name, so the agent session list can group by device.
  final Map<String, String> hostNames;
  final ThemePreference themePreference;
  final ValueChanged<AppSettings> onSettingsChanged;
  final ValueChanged<ThemePreference> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 132),
      children: [
        SettingsSection(
          label: '外观',
          children: [
            SettingsRow(
              icon: Icons.tune_rounded,
              label: '主题',
              trailing: _ThemeSegment(
                value: themePreference,
                onChanged: onThemeChanged,
              ),
            ),
            SettingsRow(
              icon: Icons.terminal_rounded,
              label: '字体大小',
              trailing: SizedBox(
                width: 158,
                child: Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 15,
                          ),
                        ),
                        child: Slider(
                          min: 11,
                          max: 16,
                          divisions: 10,
                          value: settings.fontSize,
                          onChanged: (value) => onSettingsChanged(
                            settings.copyWith(fontSize: value),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text(
                        settings.fontSize.toStringAsFixed(1),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: context.shelly.onSurface2,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _toggle(
              context,
              Icons.edit_rounded,
              '光标闪烁',
              '块状光标呼吸',
              settings.cursorBlink,
              (value) =>
                  onSettingsChanged(settings.copyWith(cursorBlink: value)),
            ),
            SettingsRow(
              icon: Icons.keyboard_alt_outlined,
              label: '扩展快捷键',
              hint: '${settings.extraKeys.length} 个按键',
              onTap: () async {
                final keys = await _showExtraKeys(context, settings.extraKeys);
                if (keys != null) {
                  onSettingsChanged(settings.copyWith(extraKeys: keys));
                }
              },
            ),
          ],
        ),
        SettingsSection(
          label: '连接',
          children: [
            _toggle(
              context,
              Icons.wifi_rounded,
              '保持活动',
              '定期发送心跳包',
              settings.keepAlive,
              (value) => onSettingsChanged(settings.copyWith(keepAlive: value)),
            ),
            _toggle(
              context,
              Icons.language_rounded,
              '自动重连',
              '断开后静默恢复',
              settings.autoReconnect,
              (value) =>
                  onSettingsChanged(settings.copyWith(autoReconnect: value)),
            ),
            _toggle(
              context,
              Icons.compress_rounded,
              '压缩传输',
              'gzip 通道',
              settings.compression,
              (value) =>
                  onSettingsChanged(settings.copyWith(compression: value)),
            ),
            SettingsRow(
              icon: Icons.key_rounded,
              label: 'SSH 密钥',
              hint: '1 个密钥',
              onTap: () => _showListSheet(
                context,
                icon: Icons.key_rounded,
                title: 'SSH 密钥',
                primary: 'id_ed25519',
                secondary: 'ed25519 · SHA256:nR1k+8f2aQ9Lm',
              ),
            ),
            _toggle(
              context,
              Icons.notifications_rounded,
              '终端响铃',
              null,
              settings.sound,
              (value) => onSettingsChanged(settings.copyWith(sound: value)),
            ),
          ],
        ),
        AgentSettingsSection(
          settings: agentSettings,
          sessions: agentSessions,
          hostNames: hostNames,
        ),
        SettingsSection(
          label: '安全',
          children: [
            _toggle(
              context,
              Icons.security_rounded,
              '生物识别锁',
              '打开应用时验证',
              settings.biometric,
              (value) => onSettingsChanged(settings.copyWith(biometric: value)),
            ),
            SettingsRow(
              icon: Icons.key_rounded,
              label: '已知主机',
              hint: '管理指纹',
              onTap: () => _showKnownHosts(context, knownHosts),
            ),
          ],
        ),
        SettingsSection(
          label: '反馈',
          children: [
            _toggle(
              context,
              Icons.vibration_rounded,
              '长按震动',
              null,
              settings.haptics,
              (value) {
                HapticFeedback.selectionClick();
                onSettingsChanged(settings.copyWith(haptics: value));
              },
            ),
          ],
        ),
        const SettingsSection(
          label: '关于',
          children: [
            SettingsRow(
              icon: Icons.info_outline_rounded,
              label: '版本',
              hint: 'Shelly 1.0.0',
            ),
            SettingsRow(
              icon: Icons.balance_rounded,
              label: '开源许可',
              hint: 'MIT',
            ),
          ],
        ),
      ],
    );
  }

  SettingsRow _toggle(
    BuildContext context,
    IconData icon,
    String label,
    String? hint,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SettingsRow(
      icon: icon,
      label: label,
      hint: hint,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  const _ThemeSegment({required this.value, required this.onChanged});

  final ThemePreference value;
  final ValueChanged<ThemePreference> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    const options = [
      (ThemePreference.light, '浅色'),
      (ThemePreference.dark, '深色'),
      (ThemePreference.system, '跟随'),
    ];
    return Container(
      width: 176,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: Material(
                color: option.$1 == value
                    ? colors.surface3
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onChanged(option.$1),
                  child: SizedBox(
                    height: 32,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (option.$1 == value) ...[
                          const Icon(Icons.check_rounded, size: 11),
                          const SizedBox(width: 3),
                        ],
                        Flexible(
                          child: Text(
                            option.$2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.onSurface2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<List<TerminalExtraKey>?> _showExtraKeys(
  BuildContext context,
  List<TerminalExtraKey> current,
) {
  return showModalBottomSheet<List<TerminalExtraKey>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.76,
      child: _ExtraKeysSheet(keys: current),
    ),
  );
}

class _ExtraKeysSheet extends StatefulWidget {
  const _ExtraKeysSheet({required this.keys});

  final List<TerminalExtraKey> keys;

  @override
  State<_ExtraKeysSheet> createState() => _ExtraKeysSheetState();
}

class _ExtraKeysSheetState extends State<_ExtraKeysSheet> {
  late List<TerminalExtraKey> _keys = List.of(widget.keys);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.keyboard_alt_outlined, size: 19),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '扩展快捷键',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      setState(() => _keys = List.of(defaultTerminalExtraKeys)),
                  tooltip: '恢复默认顺序',
                  icon: const Icon(Icons.restart_alt_rounded),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context, _keys),
                  tooltip: '保存',
                  icon: const Icon(Icons.check_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: _keys.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final key = _keys.removeAt(oldIndex);
                  _keys.insert(newIndex, key);
                });
              },
              itemBuilder: (context, index) {
                final key = _keys[index];
                return ListTile(
                  key: ValueKey(key),
                  leading: SizedBox(
                    width: 54,
                    child: Text(
                      key.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text(_extraKeyName(key)),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.drag_handle_rounded),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _extraKeyName(TerminalExtraKey key) => switch (key) {
  TerminalExtraKey.escape => 'Escape',
  TerminalExtraKey.control => 'Control',
  TerminalExtraKey.alt => 'Alt',
  TerminalExtraKey.tab => 'Tab',
  TerminalExtraKey.minus => '减号',
  TerminalExtraKey.slash => '斜杠',
  TerminalExtraKey.pipe => '管道符',
  TerminalExtraKey.tilde => '波浪号',
  TerminalExtraKey.home => 'Home',
  TerminalExtraKey.arrowUp => '上方向键',
  TerminalExtraKey.end => 'End',
  TerminalExtraKey.pageUp => 'Page Up',
  TerminalExtraKey.arrowLeft => '左方向键',
  TerminalExtraKey.arrowDown => '下方向键',
  TerminalExtraKey.arrowRight => '右方向键',
  TerminalExtraKey.pageDown => 'Page Down',
};

Future<void> _showKnownHosts(
  BuildContext context,
  KnownHostRepository repository,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.72,
      child: _KnownHostsSheet(repository: repository),
    ),
  );
}

class _KnownHostsSheet extends StatefulWidget {
  const _KnownHostsSheet({required this.repository});

  final KnownHostRepository repository;

  @override
  State<_KnownHostsSheet> createState() => _KnownHostsSheetState();
}

class _KnownHostsSheetState extends State<_KnownHostsSheet> {
  late final KnownHostsController _controller = KnownHostsController(
    widget.repository,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.security_rounded, size: 19),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '已知主机',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, child) => switch (_controller.status) {
                KnownHostsStatus.loading => const Center(
                  child: CircularProgressIndicator(),
                ),
                KnownHostsStatus.failure => _KnownHostsError(
                  message: _controller.errorMessage ?? '读取已知主机失败。',
                  onRetry: _controller.load,
                ),
                KnownHostsStatus.ready => _buildRecords(context),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecords(BuildContext context) {
    final records = _controller.records;
    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 30,
              color: context.shelly.onSurface3,
            ),
            const SizedBox(height: 10),
            Text(
              '还没有已信任的主机指纹',
              style: TextStyle(color: context.shelly.onSurface3, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: records.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final record = records[index];
        return ListTile(
          leading: const Icon(Icons.key_rounded),
          title: Text(
            '${record.host}:${record.port}',
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            '${record.algorithm}\n${record.fingerprint}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
          ),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: record.fingerprint));
            if (context.mounted) _message(context, '指纹已复制');
          },
          trailing: IconButton(
            onPressed: () => _deleteRecord(record),
            tooltip: '删除指纹',
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        );
      },
    );
  }

  Future<void> _deleteRecord(KnownHostRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除主机指纹？'),
        content: Text(
          '删除 ${record.host}:${record.port} 的 ${record.algorithm} 指纹后，下次连接会重新询问。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _controller.delete(record);
    } on KnownHostRepositoryException catch (error) {
      if (mounted) _message(context, error.message);
    }
  }

  void _message(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _KnownHostsError extends StatelessWidget {
  const _KnownHostsError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

Future<void> _showListSheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String primary,
  required String secondary,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 19),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              tileColor: context.shelly.surface,
              leading: Icon(icon),
              title: Text(primary, style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                secondary,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: secondary));
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    ),
  );
}
