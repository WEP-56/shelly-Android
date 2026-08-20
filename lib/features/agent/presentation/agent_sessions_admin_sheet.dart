import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../ui/settings_tiles.dart';
import '../data/agent_session_repository.dart';
import 'agent_session_sheet.dart';

/// Cross-host conversation管理 for the settings page: browse every stored agent
/// session, rename, delete, or clear them all.
///
/// This talks to the repository directly instead of through an
/// [AgentController], so it can reach hosts that have no terminal open. A panel
/// that is currently mounted for one of these hosts re-reads its session list the
/// next time it is opened.
Future<void> showAgentSessionsAdminSheet(
  BuildContext context, {
  required AgentSessionRepository sessions,
  required Map<String, String> hostNames,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.8,
      child: _SessionsAdminSheet(sessions: sessions, hostNames: hostNames),
    ),
  );
}

class _SessionsAdminSheet extends StatefulWidget {
  const _SessionsAdminSheet({required this.sessions, required this.hostNames});

  final AgentSessionRepository sessions;
  final Map<String, String> hostNames;

  @override
  State<_SessionsAdminSheet> createState() => _SessionsAdminSheetState();
}

class _SessionsAdminSheetState extends State<_SessionsAdminSheet> {
  List<AgentSessionSummary> _sessions = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final sessions = await widget.sessions.list();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _error = null;
        _loading = false;
      });
    } on AgentSessionException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _rename(AgentSessionSummary session) async {
    final title = await showAgentSessionTitleDialog(context, session.title);
    if (title == null) return;
    try {
      await widget.sessions.rename(session.id, title);
    } on AgentSessionException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  Future<void> _delete(AgentSessionSummary session) async {
    final confirmed = await _confirm(
      context,
      title: '删除会话',
      body: '「${session.title}」的全部消息会被删除，无法恢复。',
    );
    if (!confirmed) return;
    try {
      await widget.sessions.delete(session.id);
    } on AgentSessionException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  Future<void> _clearAll() async {
    final confirmed = await _confirm(
      context,
      title: '清空全部会话',
      body: '所有设备上的 Agent 对话记录都会被删除，无法恢复。Provider 与 API Key 不受影响。',
    );
    if (!confirmed) return;
    try {
      await widget.sessions.clear();
    } on AgentSessionException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  void _report(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  String _hostLabel(String hostId) => widget.hostNames[hostId] ?? '已删除的设备';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.forum_outlined,
            title: 'Agent 会话',
            subtitle: '按设备分组的对话记录',
            actions: [
              IconButton(
                onPressed: _sessions.isEmpty
                    ? null
                    : () => unawaited(_clearAll()),
                tooltip: '清空全部',
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '还没有 Agent 对话记录。在终端里打开 Agent 面板发一条消息就会创建。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.shelly.onSurface3),
          ),
        ),
      );
    }
    final rows = <Widget>[];
    String? lastHostId;
    for (final session in _sessions) {
      if (session.hostId != lastHostId) {
        lastHostId = session.hostId;
        rows.add(_buildHostHeader(context, session.hostId));
      }
      rows.add(_buildRow(context, session));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: rows,
    );
  }

  Widget _buildHostHeader(BuildContext context, String hostId) {
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 14, color: colors.onSurface3),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _hostLabel(hostId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.onSurface2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, AgentSessionSummary session) {
    return ListTile(
      leading: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        '${session.messageCount} 条消息 · ${formatAgentTimestamp(session.updatedAt)}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: PopupMenuButton<_AdminAction>(
        tooltip: '更多',
        onSelected: (action) => unawaited(switch (action) {
          _AdminAction.rename => _rename(session),
          _AdminAction.delete => _delete(session),
        }),
        itemBuilder: (context) => const [
          PopupMenuItem(value: _AdminAction.rename, child: Text('重命名')),
          PopupMenuItem(value: _AdminAction.delete, child: Text('删除')),
        ],
      ),
    );
  }
}

enum _AdminAction { rename, delete }

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
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
  return confirmed ?? false;
}
