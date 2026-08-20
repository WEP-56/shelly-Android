import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../domain/agent_command_approval.dart';
import 'agent_message_view.dart';

/// The approval boundary in the transcript.
///
/// The card always shows the target device and the exact command text that would
/// be written to the shell. Nothing runs until the user decides every command;
/// rewriting one produces a brand-new record (handled by the controller), so this
/// widget only ever renders what it was given.
class AgentApprovalCard extends StatelessWidget {
  const AgentApprovalCard({
    required this.approval,
    this.onApprove,
    this.onReject,
    this.onEdit,
    this.onApproveAll,
    this.onRejectAll,
    super.key,
  });

  final AgentCommandApproval approval;
  final ValueChanged<String>? onApprove;
  final ValueChanged<String>? onReject;
  final void Function(String commandId, String command)? onEdit;
  final VoidCallback? onApproveAll;
  final VoidCallback? onRejectAll;

  /// Historical records are rendered without buttons.
  bool get _interactive => onApprove != null && !approval.settled;

  bool get _hasPending => approval.commands.any(
    (draft) => draft.decision == AgentCommandDecision.pending,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final locked = approval.executing;
    final decidable = _interactive && !locked;
    return AgentRowFrame(
      icon: Icons.verified_user_outlined,
      iconColor: _hasPending && !approval.settled ? colors.primary : null,
      child: Container(
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hasPending && !approval.settled
                ? colors.primary
                : colors.line,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            const SizedBox(height: 8),
            _meta(context, '目的', approval.reason),
            _meta(context, '预期结果', approval.expectedResult),
            if (approval.supersedes != null) ...[
              const SizedBox(height: 6),
              const AgentInlineNote(
                icon: Icons.edit_note_rounded,
                text: '命令已被修改，这是需要重新批准的新申请。',
              ),
            ],
            const SizedBox(height: 8),
            for (var index = 0; index < approval.commands.length; index++) ...[
              if (index != 0) const SizedBox(height: 8),
              _CommandTile(
                index: index + 1,
                draft: approval.commands[index],
                interactive: decidable,
                onApprove: onApprove,
                onReject: onReject,
                onEdit: onEdit,
              ),
            ],
            if (locked) ...[
              const SizedBox(height: 8),
              const AgentInlineNote(
                icon: Icons.terminal_rounded,
                text: '已批准的命令正在终端里执行，输出会同时回传给 Agent。',
              ),
            ] else if (decidable && _hasPending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onRejectAll,
                      child: const Text('全部拒绝'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: onApproveAll,
                      child: const Text('全部允许'),
                    ),
                  ),
                ],
              ),
            ] else if (approval.settled && !approval.hasApproved) ...[
              const SizedBox(height: 8),
              const AgentInlineNote(
                icon: Icons.block_rounded,
                text: '本次申请没有任何命令被执行。',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.shelly;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '申请在终端执行命令',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.dns_outlined, size: 11, color: colors.onSurface3),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      approval.hostLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: colors.onSurface3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _StatePill(
          label: approval.executing
              ? '执行中'
              : approval.settled
              ? '已结束'
              : _hasPending
              ? '待批准'
              : '已决定',
          color: approval.executing || (_hasPending && !approval.settled)
              ? colors.primary
              : colors.onSurface3,
        ),
      ],
    );
  }

  Widget _meta(BuildContext context, String label, String value) {
    final text = value.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 11,
            height: 1.45,
            color: colors.onSurface2,
          ),
          children: [
            TextSpan(
              text: '$label：',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colors.onSurface3,
              ),
            ),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.index,
    required this.draft,
    required this.interactive,
    this.onApprove,
    this.onReject,
    this.onEdit,
  });

  final int index;
  final AgentCommandDraft draft;
  final bool interactive;
  final ValueChanged<String>? onApprove;
  final ValueChanged<String>? onReject;
  final void Function(String commandId, String command)? onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final scheme = Theme.of(context).colorScheme;
    final pending = draft.decision == AgentCommandDecision.pending;
    final (String decision, Color decisionColor) = switch (draft.decision) {
      AgentCommandDecision.pending => ('待批准', colors.onSurface3),
      AgentCommandDecision.approved => ('已允许', colors.primary),
      AgentCommandDecision.rejected => ('已拒绝', scheme.error),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '#$index',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: colors.onSurface3,
              ),
            ),
            const SizedBox(width: 8),
            _StatePill(label: decision, color: decisionColor),
            if (draft.decision == AgentCommandDecision.approved) ...[
              const SizedBox(width: 6),
              _StatePill(
                label: switch (draft.phase) {
                  AgentCommandPhase.waiting => '等待执行',
                  AgentCommandPhase.running => '执行中',
                  AgentCommandPhase.finished => '已执行',
                  AgentCommandPhase.failed => '执行失败',
                  AgentCommandPhase.skipped => '未执行',
                },
                color: draft.phase == AgentCommandPhase.failed
                    ? scheme.error
                    : colors.onSurface3,
              ),
            ],
            if (draft.edited) ...[
              const SizedBox(width: 6),
              _StatePill(label: '已修改', color: colors.onSurface3),
            ],
          ],
        ),
        const SizedBox(height: 5),
        AgentCodeBlock(text: draft.command, maxHeight: 140),
        if (interactive && pending) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              _TileAction(
                icon: Icons.check_rounded,
                label: '允许',
                onPressed: () => onApprove?.call(draft.id),
              ),
              const SizedBox(width: 6),
              _TileAction(
                icon: Icons.close_rounded,
                label: '拒绝',
                onPressed: () => onReject?.call(draft.id),
              ),
              const SizedBox(width: 6),
              _TileAction(
                icon: Icons.edit_outlined,
                label: '修改',
                onPressed: () => _edit(context),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final edited = await showAgentCommandEditor(context, draft.command);
    if (edited == null) return;
    onEdit?.call(draft.id, edited);
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 32),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Prompts for a rewritten command. Returns null when the user cancels or leaves
/// the text unchanged.
Future<String?> showAgentCommandEditor(
  BuildContext context,
  String command,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _CommandEditorDialog(command: command),
  );
  if (result == null) return null;
  final edited = result.trim();
  if (edited.isEmpty || edited == command.trim()) return null;
  return edited;
}

/// The dialog owns its [TextEditingController].
///
/// `showDialog` completes as soon as the route is popped, while the dialog
/// subtree stays mounted for the exit transition. Disposing the controller right
/// after the await therefore tears it down under a live [TextField] and trips
/// `_dependents.isEmpty` when the route finally unmounts, so the controller is
/// tied to this State's lifetime instead.
class _CommandEditorDialog extends StatefulWidget {
  const _CommandEditorDialog({required this.command});

  final String command;

  @override
  State<_CommandEditorDialog> createState() => _CommandEditorDialogState();
}

class _CommandEditorDialogState extends State<_CommandEditorDialog> {
  late final _controller = TextEditingController(text: widget.command);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改命令'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '修改后会生成一条新的申请，需要重新批准才会执行。',
            style: TextStyle(fontSize: 11.5, color: context.shelly.onSurface3),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
