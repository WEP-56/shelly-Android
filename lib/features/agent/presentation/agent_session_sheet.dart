import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../ui/settings_tiles.dart';
import '../application/agent_controller.dart';
import '../data/agent_session_repository.dart';

/// In-panel conversation manager: new / switch / rename / delete for the host the
/// panel is attached to.
Future<void> showAgentSessionSheet(
  BuildContext context,
  AgentController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.68,
      child: _AgentSessionSheet(controller: controller),
    ),
  );
}

class _AgentSessionSheet extends StatelessWidget {
  const _AgentSessionSheet({required this.controller});

  final AgentController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, child) => Column(
          children: [
            SheetHeader(
              icon: Icons.forum_outlined,
              title: '会话',
              subtitle: controller.isRunning
                  ? '本轮运行中，无法切换会话'
                  : '当前设备的 Agent 对话',
              actions: [
                IconButton(
                  onPressed: controller.isRunning
                      ? null
                      : () async {
                          await controller.newSession();
                          if (context.mounted) Navigator.pop(context);
                        },
                  tooltip: '新建会话',
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Expanded(child: _buildList(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final sessions = controller.sessions;
    if (sessions.isEmpty) {
      return Center(
        child: Text(
          '还没有会话，发一条消息就会自动创建。',
          style: TextStyle(fontSize: 12, color: context.shelly.onSurface3),
        ),
      );
    }
    final currentId = controller.currentSession?.id;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: sessions.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final session = sessions[index];
        final selected = session.id == currentId;
        return ListTile(
          leading: Icon(
            selected ? Icons.chat_rounded : Icons.chat_bubble_outline_rounded,
            size: 19,
            color: selected ? context.shelly.primary : null,
          ),
          title: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          subtitle: Text(
            '${session.messageCount} 条消息 · ${formatAgentTimestamp(session.updatedAt)}',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: PopupMenuButton<_SessionAction>(
            tooltip: '更多',
            onSelected: (action) => _run(context, action, session),
            itemBuilder: (context) => const [
              PopupMenuItem(value: _SessionAction.rename, child: Text('重命名')),
              PopupMenuItem(value: _SessionAction.delete, child: Text('删除')),
            ],
          ),
          onTap: controller.isRunning || selected
              ? null
              : () async {
                  await controller.switchSession(session.id);
                  if (context.mounted) Navigator.pop(context);
                },
        );
      },
    );
  }

  Future<void> _run(
    BuildContext context,
    _SessionAction action,
    AgentSessionSummary session,
  ) async {
    switch (action) {
      case _SessionAction.rename:
        final title = await showAgentSessionTitleDialog(context, session.title);
        if (title == null) return;
        await controller.renameSession(session.id, title);
      case _SessionAction.delete:
        if (controller.isRunning) return;
        final confirmed = await _confirmDelete(context, session.title);
        if (!confirmed) return;
        await controller.deleteSession(session.id);
    }
  }
}

enum _SessionAction { rename, delete }

/// Asks for a new session title. Returns null when the user cancels, clears the
/// field, or leaves the title unchanged.
Future<String?> showAgentSessionTitleDialog(
  BuildContext context,
  String current,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _TitleDialog(current: current),
  );
  if (result == null) return null;
  final title = result.trim();
  if (title.isEmpty || title == current) return null;
  return title;
}

/// The dialog owns its [TextEditingController].
///
/// `showDialog` completes on pop while the dialog subtree is still mounted for
/// the exit transition, so disposing the controller right after the await would
/// tear it down under a live [TextField] and trip `_dependents.isEmpty` when the
/// route unmounts.
class _TitleDialog extends StatefulWidget {
  const _TitleDialog({required this.current});

  final String current;

  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除会话'),
      content: Text('「$title」的全部消息会被删除，无法恢复。'),
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

/// Compact timestamp for session rows: time today, date otherwise.
String formatAgentTimestamp(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${_two(local.hour)}:${_two(local.minute)}';
  }
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}

String _two(int part) => part.toString().padLeft(2, '0');
