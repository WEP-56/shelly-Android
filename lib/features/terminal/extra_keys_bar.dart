import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../core/terminal/terminal_input.dart';
import '../../core/terminal/terminal_session_adapter.dart';

class ExtraKeysBar extends StatelessWidget {
  const ExtraKeysBar({
    required this.keys,
    required this.controlState,
    required this.altState,
    required this.onKey,
    required this.onModifierLongPress,
    super.key,
  });

  final List<TerminalExtraKey> keys;
  final TerminalModifierState controlState;
  final TerminalModifierState altState;
  final ValueChanged<TerminalExtraKey> onKey;
  final ValueChanged<TerminalExtraKey> onModifierLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        itemCount: keys.length,
        separatorBuilder: (context, index) => const SizedBox(width: 5),
        itemBuilder: (context, index) {
          final key = keys[index];
          return _ExtraKeyButton(
            key: ValueKey(key),
            terminalKey: key,
            modifierState: switch (key) {
              TerminalExtraKey.control => controlState,
              TerminalExtraKey.alt => altState,
              _ => TerminalModifierState.inactive,
            },
            onTap: () => onKey(key),
            onLongPress: () =>
                key.isModifier ? onModifierLongPress(key) : onKey(key),
          );
        },
      ),
    );
  }
}

class _ExtraKeyButton extends StatefulWidget {
  const _ExtraKeyButton({
    required this.terminalKey,
    required this.modifierState,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  final TerminalExtraKey terminalKey;
  final TerminalModifierState modifierState;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_ExtraKeyButton> createState() => _ExtraKeyButtonState();
}

class _ExtraKeyButtonState extends State<_ExtraKeyButton> {
  static const _repeatDelay = Duration(milliseconds: 85);

  Timer? _repeatTimer;
  bool _pressed = false;

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  void _tap() {
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  void _longPressStart(LongPressStartDetails details) {
    HapticFeedback.mediumImpact();
    widget.onLongPress();
    if (!widget.terminalKey.isRepeatable) return;
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(_repeatDelay, (_) => widget.onLongPress());
  }

  void _longPressEnd(LongPressEndDetails details) {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (mounted) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    final active = widget.modifierState != TerminalModifierState.inactive;
    final locked = widget.modifierState == TerminalModifierState.locked;
    return Semantics(
      button: true,
      label: widget.terminalKey.label,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _tap,
        onLongPressStart: _longPressStart,
        onLongPressEnd: _longPressEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          constraints: const BoxConstraints(minWidth: 42),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: active
                ? colors.primary
                : _pressed
                ? colors.surface3
                : colors.surface2,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.terminalKey.label,
                  style: TextStyle(
                    color: active ? colors.onPrimary : colors.onSurface2,
                    fontFamily: 'monospace',
                    fontSize: widget.terminalKey.label.length > 3 ? 9.5 : 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (locked) ...[
                  const SizedBox(width: 3),
                  Icon(Icons.lock_rounded, size: 9, color: colors.onPrimary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
