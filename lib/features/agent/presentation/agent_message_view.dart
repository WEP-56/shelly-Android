import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../application/agent_controller.dart';
import '../domain/agent_event.dart';
import '../domain/agent_message.dart';

/// Transcript rows for the agent panel.
///
/// Every visible state of §6.1 gets its own row type: text deltas
/// ([AgentAssistantBubble]), read tools ([AgentActiveToolRow] while running and
/// [AgentToolResultRow] once finished), provider status
/// ([AgentStatusRow]) and failures ([AgentErrorNotice]). Command approval lives
/// in `agent_approval_card.dart`.

/// Left gutter shared by every assistant-side row so avatars line up.
class AgentRowFrame extends StatelessWidget {
  const AgentRowFrame({
    required this.icon,
    required this.child,
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final Widget child;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: colors.surface3,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 13, color: iconColor ?? colors.onSurface2),
        ),
        const SizedBox(width: 8),
        Expanded(child: child),
      ],
    );
  }
}

class AgentUserBubble extends StatelessWidget {
  const AgentUserBubble({required this.message, super.key});

  final AgentUserMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(5),
          ),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: colors.onPrimary,
            fontSize: 12.5,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

/// Assistant text. Reasoning is never rendered here — the provider adapters map
/// it to [AgentStatusKind.reasoning] instead.
class AgentAssistantBubble extends StatelessWidget {
  const AgentAssistantBubble({
    required this.message,
    this.streaming = false,
    super.key,
  });

  final AgentAssistantMessage message;
  final bool streaming;

  /// A message that carries neither text nor a failure has nothing to show: its
  /// tool calls are rendered as tool rows instead.
  static bool hasVisibleContent(AgentAssistantMessage message) =>
      message.text.trim().isNotEmpty ||
      message.isFailed ||
      (message.errorMessage?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final text = message.text;
    final error = message.errorMessage;
    return AgentRowFrame(
      icon: Icons.smart_toy_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(5),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: text.isEmpty && streaming
                ? const AgentTypingDots()
                : SelectableText(
                    text.isEmpty ? '（本轮没有文本输出）' : text,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: text.isEmpty
                          ? colors.onSurface3
                          : colors.onSurface,
                    ),
                  ),
          ),
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: 6),
            AgentErrorNotice(message: error),
          ] else if (message.stopReason == AgentStopReason.aborted) ...[
            const SizedBox(height: 6),
            const AgentInlineNote(
              icon: Icons.stop_circle_outlined,
              text: '本轮已被停止。',
            ),
          ] else if (message.stopReason == AgentStopReason.length) ...[
            const SizedBox(height: 6),
            const AgentInlineNote(
              icon: Icons.content_cut_rounded,
              text: '输出达到模型上限，内容可能不完整。',
            ),
          ],
        ],
      ),
    );
  }
}

/// A finished tool call. Collapsed to a summary line; tap to read the exact text
/// that was handed back to the model.
class AgentToolResultRow extends StatefulWidget {
  const AgentToolResultRow({
    required this.message,
    required this.label,
    super.key,
  });

  final AgentToolResultMessage message;
  final String label;

  @override
  State<AgentToolResultRow> createState() => _AgentToolResultRowState();
}

class _AgentToolResultRowState extends State<AgentToolResultRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final error = widget.message.isError;
    final accent = error ? Theme.of(context).colorScheme.error : colors.primary;
    final text = widget.message.text.trim();
    final firstLine = text.isEmpty
        ? '没有输出'
        : text
              .split('\n')
              .firstWhere((line) => line.trim().isNotEmpty, orElse: () => text);
    return AgentRowFrame(
      icon: error ? Icons.error_outline_rounded : Icons.handyman_outlined,
      iconColor: error ? accent : null,
      child: Material(
        color: colors.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: error ? accent : colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: error ? accent : colors.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: colors.onSurface3,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_expanded)
                  AgentCodeBlock(text: text.isEmpty ? '没有输出' : text)
                else
                  Text(
                    firstLine.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      height: 1.4,
                      color: colors.onSurface2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A read tool that is still running.
class AgentActiveToolRow extends StatelessWidget {
  const AgentActiveToolRow({required this.tool, super.key});

  final AgentActiveTool tool;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return AgentRowFrame(
      icon: Icons.handyman_outlined,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: colors.onSurface2,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '正在${tool.label}…',
                style: TextStyle(fontSize: 11.5, color: colors.onSurface2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Provider-sanctioned status line. Only carries the summary the provider itself
/// published — never private chain of thought.
class AgentStatusRow extends StatelessWidget {
  const AgentStatusRow({required this.status, super.key});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.only(left: 32),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: colors.onSurface3,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              _label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurface3),
            ),
          ),
        ],
      ),
    );
  }

  String get _label {
    final base = switch (status.kind) {
      AgentStatusKind.connecting => '正在连接模型',
      AgentStatusKind.streaming => '正在生成回复',
      AgentStatusKind.reasoning => '正在思考',
      AgentStatusKind.retrying => '连接失败，正在重试',
      AgentStatusKind.finishing => '正在收尾',
    };
    final attempt = status.attempt;
    final summary = status.summary?.trim();
    final buffer = StringBuffer(base);
    if (attempt != null) buffer.write('（第 $attempt 次）');
    if (summary != null && summary.isNotEmpty) buffer.write(' · $summary');
    return buffer.toString();
  }
}

class AgentErrorNotice extends StatelessWidget {
  const AgentErrorNotice({required this.message, this.onDismiss, super.key});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Container(
      padding: EdgeInsets.fromLTRB(11, 9, onDismiss == null ? 11 : 4, 9),
      decoration: BoxDecoration(
        color: error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: error),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: error),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              tooltip: '忽略',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}

class AgentInlineNote extends StatelessWidget {
  const AgentInlineNote({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Row(
      children: [
        Icon(icon, size: 13, color: colors.onSurface3),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11, color: colors.onSurface3),
          ),
        ),
      ],
    );
  }
}

/// Monospace block for tool output and command text.
class AgentCodeBlock extends StatelessWidget {
  const AgentCodeBlock({
    required this.text,
    this.maxHeight = 240,
    this.selectable = true,
    super.key,
  });

  final String text;
  final double maxHeight;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 10.5,
      height: 1.45,
      color: colors.terminalOutput,
    );
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        child: selectable
            ? SelectableText(text, style: style)
            : Text(text, style: style),
      ),
    );
  }
}

class AgentTypingDots extends StatefulWidget {
  const AgentTypingDots({super.key});

  @override
  State<AgentTypingDots> createState() => _AgentTypingDotsState();
}

class _AgentTypingDotsState extends State<AgentTypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final phase = (_controller.value + index * 0.22) % 1;
            final opacity = 0.35 + (1 - (phase * 2 - 1).abs()) * 0.65;
            return Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: context.shelly.onSurface2.withValues(alpha: opacity),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
