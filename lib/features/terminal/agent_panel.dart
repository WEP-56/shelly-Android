import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../ui/shelly_icon_button.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({
    required this.onClose,
    required this.onCommandRequested,
    required this.onInputFocusChanged,
    super.key,
  });

  final VoidCallback onClose;
  final ValueChanged<String> onCommandRequested;
  final ValueChanged<bool> onInputFocusChanged;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final List<_AgentMessage> _messages = [
    const _AgentMessage(user: false, text: '我在。可以分析日志、磁盘、内存、网络；给出的命令点一下即可执行。'),
  ];
  Timer? _streamTimer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    _controller.dispose();
    _focusNode
      ..removeListener(_handleFocus)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleFocus() => widget.onInputFocusChanged(_focusNode.hasFocus);

  void _send() {
    final input = _controller.text.trim();
    if (input.isEmpty || _busy) return;
    _controller.clear();
    final reply = input.contains('内存')
        ? '建议先读取整体内存水位和缓存，再判断是否存在持续压力。'
        : '我会先读取当前磁盘占用，再根据结果继续分析。';
    final command = input.contains('内存') ? 'free -h' : 'df -h';
    setState(() {
      _messages.add(_AgentMessage(user: true, text: input));
      _messages.add(const _AgentMessage(user: false, text: ''));
      _busy = true;
    });
    _scrollToBottom();
    var index = 0;
    _streamTimer = Timer.periodic(const Duration(milliseconds: 26), (timer) {
      if (!mounted) return;
      if (index >= reply.length) {
        timer.cancel();
        setState(() {
          final current = _messages.last;
          _messages[_messages.length - 1] = current.copyWith(command: command);
          _busy = false;
        });
        _scrollToBottom();
        return;
      }
      setState(() {
        final current = _messages.last;
        _messages[_messages.length - 1] = current.copyWith(
          text: current.text + reply[index],
        );
        index += 1;
      });
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.surface,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Icon(
                  Icons.smart_toy_outlined,
                  size: 17,
                  color: colors.onSurface2,
                ),
                const SizedBox(width: 9),
                const Text(
                  'Agent',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
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
          ),
          Divider(height: 1, thickness: 1, color: colors.line),
          Expanded(
            child: ListView.separated(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              itemCount: _messages.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final message = _messages[index];
                if (message.user) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
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
                      child: Icon(
                        Icons.smart_toy_outlined,
                        size: 13,
                        color: colors.onSurface2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surface2,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(5),
                                topRight: Radius.circular(16),
                                bottomLeft: Radius.circular(16),
                                bottomRight: Radius.circular(16),
                              ),
                            ),
                            child: message.text.isEmpty
                                ? const _TypingDots()
                                : Text(
                                    message.text,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      height: 1.45,
                                    ),
                                  ),
                          ),
                          if (message.command != null) ...[
                            const SizedBox(height: 7),
                            Material(
                              color: colors.elevated,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: colors.line),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () =>
                                    widget.onCommandRequested(message.command!),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.code_rounded,
                                        size: 13,
                                        color: colors.onSurface2,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          message.command!,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        Icons.play_arrow_rounded,
                                        size: 14,
                                        color: colors.onSurface3,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 9),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: '问问 Agent…',
                      hintStyle: TextStyle(
                        color: colors.onSurface3,
                        fontSize: 12.5,
                      ),
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
                  color: colors.primary,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _send,
                    child: SizedBox.square(
                      dimension: 40,
                      child: Icon(
                        Icons.send_rounded,
                        size: 17,
                        color: colors.onPrimary,
                      ),
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
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
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

class _AgentMessage {
  const _AgentMessage({required this.user, required this.text, this.command});

  final bool user;
  final String text;
  final String? command;

  _AgentMessage copyWith({String? text, String? command}) {
    return _AgentMessage(
      user: user,
      text: text ?? this.text,
      command: command ?? this.command,
    );
  }
}
