import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/ssh/ssh_connection_event.dart';
import '../../core/ssh/ssh_models.dart';
import '../../core/ssh/ssh_session_controller.dart';

/// Shows the connection log of one SSH session.
///
/// The log exists so a dropped connection is reportable: it records state
/// transitions, failure stages, heartbeat results and reconnect attempts, and
/// deliberately records no command text, no paths and no credentials.
Future<void> showConnectionDiagnostics(
  BuildContext context, {
  required HostProfile host,
  required SshSessionController session,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) =>
        ConnectionDiagnosticsSheet(host: host, session: session),
  );
}

class ConnectionDiagnosticsSheet extends StatelessWidget {
  const ConnectionDiagnosticsSheet({
    required this.host,
    required this.session,
    super.key,
  });

  final HostProfile host;
  final SshSessionController session;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Material(
          color: colors.elevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(
            listenable: session,
            builder: (context, child) {
              final events = session.connectionEvents.reversed.toList();
              return Column(
                children: [
                  _buildHeader(context, events),
                  const Divider(height: 1),
                  Expanded(
                    child: events.isEmpty
                        ? Center(
                            child: Text(
                              '暂无连接事件。',
                              style: TextStyle(color: colors.onSurface3),
                            ),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                            itemCount: events.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) =>
                                _EventTile(event: events[index]),
                          ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, List<SshConnectionEvent> events) {
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '连接诊断',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '${host.host}:${host.port} · ${session.state.label} · '
                  'SFTP 通道 ${session.openSftpChannels}/'
                  '${SshSessionController.maxSftpChannels}',
                  style: TextStyle(color: colors.onSurface3, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  '仅记录状态与异常类型，不含命令内容与任何密钥。',
                  style: TextStyle(color: colors.onSurface3, fontSize: 10),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制',
            onPressed: events.isEmpty ? null : () => _copy(context, events),
            icon: const Icon(Icons.copy_all_rounded),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(
    BuildContext context,
    List<SshConnectionEvent> events,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final lines = [
      'Shelly 连接诊断 ${host.host}:${host.port}',
      for (final event in events.reversed)
        '${_timestamp(event.at)} [${_kindLabel(event.kind)}] ${event.message}'
            '${event.errorType == null ? '' : ' (${event.errorType})'}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    messenger.showSnackBar(const SnackBar(content: Text('已复制连接诊断')));
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final SshConnectionEvent event;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            _kindIcon(event.kind),
            size: 15,
            color: _kindColor(context, event.kind),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.message,
                style: const TextStyle(fontSize: 12, height: 1.35),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  _timestamp(event.at),
                  if (event.stage != null) '阶段：${event.stage!.label}',
                  if (event.errorType != null) event.errorType!,
                ].join(' · '),
                style: TextStyle(
                  color: colors.onSurface3,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _timestamp(DateTime at) {
  final time = at.toLocal();
  final hours = time.hour.toString().padLeft(2, '0');
  final minutes = time.minute.toString().padLeft(2, '0');
  final seconds = time.second.toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _kindLabel(SshConnectionEventKind kind) => switch (kind) {
  SshConnectionEventKind.state => '状态',
  SshConnectionEventKind.health => '心跳',
  SshConnectionEventKind.reconnect => '重连',
  SshConnectionEventKind.warning => '警告',
  SshConnectionEventKind.failure => '失败',
  SshConnectionEventKind.channel => '通道',
};

IconData _kindIcon(SshConnectionEventKind kind) => switch (kind) {
  SshConnectionEventKind.state => Icons.swap_horiz_rounded,
  SshConnectionEventKind.health => Icons.favorite_border_rounded,
  SshConnectionEventKind.reconnect => Icons.autorenew_rounded,
  SshConnectionEventKind.warning => Icons.warning_amber_rounded,
  SshConnectionEventKind.failure => Icons.error_outline_rounded,
  SshConnectionEventKind.channel => Icons.lan_outlined,
};

Color _kindColor(BuildContext context, SshConnectionEventKind kind) {
  final colors = context.shelly;
  return switch (kind) {
    SshConnectionEventKind.failure => Theme.of(context).colorScheme.error,
    SshConnectionEventKind.warning => const Color(0xFFC19328),
    SshConnectionEventKind.reconnect => colors.primary,
    _ => colors.onSurface2,
  };
}
