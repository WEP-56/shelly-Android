import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../terminal/connection_diagnostics_sheet.dart';
import 'server_status_service.dart';

Future<void> showServerStatusDialog(
  BuildContext context, {
  required HostProfile host,
  required SshSessionController session,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ServerStatusDialog(
      host: host,
      session: session,
      service: ServerStatusService(session),
    ),
  );
}

class ServerStatusDialog extends StatefulWidget {
  const ServerStatusDialog({
    required this.host,
    required this.session,
    required this.service,
    super.key,
  });

  final HostProfile host;
  final SshSessionController session;
  final ServerStatusService service;

  @override
  State<ServerStatusDialog> createState() => _ServerStatusDialogState();
}

class _ServerStatusDialogState extends State<ServerStatusDialog> {
  ServerStatusCancellationToken? _cancellationToken;
  ServerStatusSnapshot? _snapshot;
  String? _error;
  bool _loading = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _cancellationToken?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    _cancellationToken?.cancel();
    final token = ServerStatusCancellationToken();
    _cancellationToken = token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.service.fetch(cancellationToken: token);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on ServerStatusCancelled {
      // Closing the dialog or retrying intentionally cancels this request.
    } on ServerStatusException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              title: _snapshot?.hostname ?? widget.host.name,
              subtitle: '${widget.host.host}:${widget.host.port}',
              onClose: () => Navigator.pop(context),
            ),
            const SizedBox(height: 18),
            Flexible(child: _buildContent()),
            const SizedBox(height: 4),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  /// The diagnostics entry lives outside [_buildContent] so it stays reachable
  /// while the status snapshot itself is loading or failing — a broken link is
  /// exactly when the user needs the connection log.
  Widget _buildFooter() {
    return Row(
      children: [
        TextButton.icon(
          onPressed: () => showConnectionDiagnostics(
            context,
            host: widget.host,
            session: widget.session,
          ),
          icon: const Icon(Icons.monitor_heart_outlined, size: 18),
          label: const Text('连接诊断'),
        ),
        const Spacer(),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新状态',
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading && _snapshot == null) {
      return const _StatusMessage(
        icon: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        title: '正在读取服务器状态',
        detail: '通过当前 SSH 连接获取一次快照',
      );
    }
    if (_error != null && _snapshot == null) {
      return _StatusMessage(
        icon: Icon(
          Icons.error_outline_rounded,
          color: Theme.of(context).colorScheme.error,
        ),
        title: _error!,
        detail: '终端连接不会受影响',
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重试'),
        ),
      );
    }

    final snapshot = _snapshot!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) ...[
            _InlineError(message: _error!, onRetry: _load),
            const SizedBox(height: 14),
          ],
          _DetailRow(label: '系统', value: snapshot.system),
          _DetailRow(label: 'CPU', value: _cpuDescription(snapshot.cpu)),
          const SizedBox(height: 14),
          _UsageMetric(
            label: 'CPU 使用率',
            value: snapshot.cpu.usage,
            detail: _percent(snapshot.cpu.usage),
          ),
          _UsageMetric(
            label: '内存',
            value: snapshot.memory.usage,
            detail: _memoryDescription(snapshot.memory),
          ),
          _UsageMetric(
            label: '根磁盘',
            value: snapshot.disk.usage,
            detail: _diskDescription(snapshot.disk),
          ),
          const Divider(height: 24),
          _DetailRow(
            label: '负载',
            value: snapshot.loadAverage.isEmpty
                ? null
                : snapshot.loadAverage
                      .map((value) => value.toStringAsFixed(2))
                      .join('  '),
            monospace: true,
          ),
          _DetailRow(label: '运行时间', value: _duration(snapshot.uptime)),
        ],
      ),
    );
  }

  String? _cpuDescription(ServerStatusCpu cpu) {
    final parts = <String>[?cpu.model, if (cpu.cores != null) '${cpu.cores} 核'];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _memoryDescription(ServerStatusMemory memory) {
    final total = memory.totalBytes;
    final available = memory.availableBytes;
    if (total == null || available == null) return '不可用';
    final used = (total - available).clamp(0, total);
    return '${_bytes(used)} / ${_bytes(total)}';
  }

  String _diskDescription(ServerStatusDisk disk) {
    final total = disk.totalBytes;
    final used = disk.usedBytes;
    if (total == null || used == null) return '不可用';
    return '${_bytes(used)} / ${_bytes(total)}';
  }

  String _percent(double? value) =>
      value == null ? '不可用' : '${(value * 100).round()}%';

  String _bytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String? _duration(Duration? duration) {
    if (duration == null) return null;
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24);
    final minutes = duration.inMinutes.remainder(60);
    return [
          if (days > 0) '$days 天',
          if (hours > 0) '$hours 小时',
          if (days == 0 && minutes > 0) '$minutes 分钟',
        ].join(' ').nullIfEmpty ??
        '不足 1 分钟';
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.shelly.surface3,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.speed_rounded,
            size: 20,
            color: context.shelly.onSurface2,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onClose,
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final Widget icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 5),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.shelly.onSurface3, fontSize: 11),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 11.5))),
        IconButton(
          onPressed: onRetry,
          tooltip: '重试',
          icon: const Icon(Icons.refresh_rounded, size: 19),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String? value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(
              label,
              style: TextStyle(color: context.shelly.onSurface3, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value ?? '不可用',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: monospace ? 'monospace' : null,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final double? value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: context.shelly.onSurface2,
                    fontSize: 11.5,
                  ),
                ),
              ),
              Text(
                detail,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value ?? 0,
              minHeight: 6,
              backgroundColor: context.shelly.surface3,
              color: value == null
                  ? context.shelly.line2
                  : context.shelly.primary,
            ),
          ),
        ],
      ),
    );
  }
}
