import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../ui/shelly_icon_button.dart';
import '../application/agent_controller.dart';
import '../domain/agent_message.dart';
import '../tools/request_commands_tool.dart';
import 'agent_approval_card.dart';
import 'agent_message_view.dart';
import 'agent_session_sheet.dart';

/// The agent panel mounted over the bottom half of the terminal.
///
/// It renders exactly what [AgentController] publishes and nothing else: text
/// deltas, running read tools, provider status, tool results, the live approval
/// card and errors. Commands reach the shell only through the approval card.
class AgentPanel extends StatefulWidget {
  const AgentPanel({
    required this.controller,
    required this.onClose,
    required this.onInputFocusChanged,
    super.key,
  });

  final AgentController controller;
  final VoidCallback onClose;
  final ValueChanged<bool> onInputFocusChanged;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController();
  final _focusNode = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocus);
    widget.controller.addListener(_handleControllerChange);
  }

  @override
  void didUpdateWidget(covariant AgentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChange);
    widget.controller.addListener(_handleControllerChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChange);
    _focusNode
      ..removeListener(_handleFocus)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _handleFocus() => widget.onInputFocusChanged(_focusNode.hasFocus);

  /// Keeps the transcript pinned to the newest row, unless the user scrolled up
  /// to read something.
  void _handleControllerChange() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > 160) return;
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final controller = widget.controller;
    if (controller.isRunning) {
      controller.stop();
      return;
    }
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _scrollToBottom();
    await controller.send(text);
    _scrollToBottom();
  }

  Future<void> _openSessions() =>
      showAgentSessionSheet(context, widget.controller);

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.surface,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, child) {
          final error = widget.controller.error;
          return Column(
            children: [
              _buildHeader(context),
              Divider(height: 1, thickness: 1, color: colors.line),
              Expanded(child: _buildBody(context)),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: AgentErrorNotice(
                    message: error,
                    onDismiss: widget.controller.clearError,
                  ),
                ),
              Divider(height: 1, thickness: 1, color: colors.line),
              _buildComposer(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.shelly;
    final controller = widget.controller;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.smart_toy_outlined, size: 17, color: colors.onSurface2),
          const SizedBox(width: 9),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openSessions,
              onLongPress: _openSessions,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Agent',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: colors.onSurface3),
                  ),
                ],
              ),
            ),
          ),
          ShellyIconButton(
            icon: Icons.add_comment_outlined,
            tooltip: '新建会话',
            dimension: 38,
            size: 17,
            onPressed: controller.isRunning
                ? null
                : () => unawaited(controller.newSession()),
          ),
          ShellyIconButton(
            icon: Icons.forum_outlined,
            tooltip: '会话列表',
            dimension: 38,
            size: 17,
            onPressed: () => unawaited(_openSessions()),
          ),
          ShellyIconButton(
            icon: Icons.close_rounded,
            tooltip: '收起',
            dimension: 38,
            size: 18,
            onPressed: widget.onClose,
          ),
          const SizedBox(width: 7),
        ],
      ),
    );
  }

  String get _subtitle {
    final controller = widget.controller;
    final parts = <String>[controller.currentSession?.title ?? '新会话'];
    final provider = controller.provider;
    if (provider != null) parts.add(provider.model);
    final usage = controller.usage;
    if (!usage.isEmpty) parts.add('${usage.totalTokens} tokens');
    return parts.join(' · ');
  }

  Widget _buildBody(BuildContext context) {
    if (widget.controller.isLoading) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final rows = _buildRows();
    if (rows.isEmpty) return _buildEmpty(context);
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      itemCount: rows.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) => rows[index],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final colors = context.shelly;
    final configured = widget.controller.isConfigured;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              configured
                  ? Icons.smart_toy_outlined
                  : Icons.settings_suggest_outlined,
              size: 30,
              color: colors.onSurface3,
            ),
            const SizedBox(height: 10),
            Text(
              configured ? '我只读取终端上下文' : '还没有配置 Agent Provider',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.onSurface2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              configured
                  ? '任何要写入这台设备的命令都会先逐条向你申请，批准后才会进入终端。'
                  : '到「设置 → Agent」添加 Provider 和 API Key 后即可开始。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: colors.onSurface3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Flattens the transcript into rows.
  ///
  /// A finished `request_commands` result is preceded by its approval trail, so
  /// the record the user acted on — including any command they rewrote — stays
  /// visible next to the output it produced.
  List<Widget> _buildRows() {
    final controller = widget.controller;
    final rows = <Widget>[];
    for (final message in controller.messages) {
      switch (message) {
        case AgentUserMessage():
          rows.add(AgentUserBubble(message: message));
        case AgentAssistantMessage():
          if (AgentAssistantBubble.hasVisibleContent(message)) {
            rows.add(AgentAssistantBubble(message: message));
          }
        case AgentToolResultMessage():
          if (message.toolName == RequestCommandsTool.toolName) {
            for (final approval in controller.approvalsFor(
              message.toolCallId,
            )) {
              rows.add(
                AgentApprovalCard(
                  key: ValueKey('approval-${approval.id}'),
                  approval: approval,
                ),
              );
            }
          }
          rows.add(
            AgentToolResultRow(
              key: ValueKey('tool-${message.toolCallId}'),
              message: message,
              label: controller.toolLabel(message.toolName),
            ),
          );
      }
    }
    final streaming = controller.streamingMessage;
    if (streaming != null &&
        (streaming.text.isNotEmpty || controller.activeTool == null)) {
      rows.add(AgentAssistantBubble(message: streaming, streaming: true));
    }
    final pending = controller.pendingApproval;
    if (pending != null) {
      rows.add(
        AgentApprovalCard(
          key: ValueKey('pending-${pending.id}'),
          approval: pending,
          onApprove: controller.approveCommand,
          onReject: controller.rejectCommand,
          onEdit: controller.editCommand,
          onApproveAll: controller.approveAll,
          onRejectAll: controller.rejectAll,
        ),
      );
    }
    final tool = controller.activeTool;
    if (tool != null && tool.toolName != RequestCommandsTool.toolName) {
      rows.add(AgentActiveToolRow(tool: tool));
    }
    final status = controller.status;
    if (status != null) rows.add(AgentStatusRow(status: status));
    return rows;
  }

  Widget _buildComposer(BuildContext context) {
    final colors = context.shelly;
    final running = widget.controller.isRunning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focusNode,
              enabled: !running,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_send()),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: running ? 'Agent 正在运行…' : '问问 Agent…',
                hintStyle: TextStyle(color: colors.onSurface3, fontSize: 12.5),
                filled: true,
                fillColor: colors.surface2,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: running ? colors.surface3 : colors.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => unawaited(_send()),
              child: SizedBox.square(
                dimension: 40,
                child: Icon(
                  running ? Icons.stop_rounded : Icons.send_rounded,
                  size: 17,
                  color: running ? colors.onSurface : colors.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
