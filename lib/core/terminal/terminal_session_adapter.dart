import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_session_controller.dart';
import 'terminal_input.dart';

enum TerminalModifierState { inactive, oneShot, locked }

class TerminalSessionAdapter extends ChangeNotifier {
  TerminalSessionAdapter({
    required SshSessionController session,
    this.onInputError,
  }) : _session = session {
    terminal = Terminal(
      maxLines: 5000,
      platform: TerminalTargetPlatform.android,
    );
    terminal.inputHandler = _ModifierInputHandler(this);
    terminal.onOutput = _sendOutput;
    terminal.onResize = _resize;
    _outputSubscription = _session.output.listen(_queueOutput);
  }

  static const _flushInterval = Duration(milliseconds: 16);

  final SshSessionController _session;
  final void Function(Object error)? onInputError;
  final StringBuffer _pendingOutput = StringBuffer();

  late final Terminal terminal;
  late final StreamSubscription<String> _outputSubscription;
  Timer? _flushTimer;
  TerminalModifierState _controlState = TerminalModifierState.inactive;
  TerminalModifierState _altState = TerminalModifierState.inactive;
  bool _bypassModifiers = false;
  bool _disposed = false;

  TerminalModifierState get controlState => _controlState;
  TerminalModifierState get altState => _altState;

  void toggleModifier(TerminalExtraKey key, {required bool lock}) {
    switch (key) {
      case TerminalExtraKey.control:
        _controlState = _nextModifierState(_controlState, lock: lock);
      case TerminalExtraKey.alt:
        _altState = _nextModifierState(_altState, lock: lock);
      default:
        return;
    }
    notifyListeners();
  }

  void sendKey(TerminalExtraKey key) {
    final terminalKey = switch (key) {
      TerminalExtraKey.escape => TerminalKey.escape,
      TerminalExtraKey.tab => TerminalKey.tab,
      TerminalExtraKey.minus => TerminalKey.minus,
      TerminalExtraKey.slash => TerminalKey.slash,
      TerminalExtraKey.pipe => TerminalKey.backslash,
      TerminalExtraKey.tilde => TerminalKey.backquote,
      TerminalExtraKey.home => TerminalKey.home,
      TerminalExtraKey.arrowUp => TerminalKey.arrowUp,
      TerminalExtraKey.end => TerminalKey.end,
      TerminalExtraKey.pageUp => TerminalKey.pageUp,
      TerminalExtraKey.arrowLeft => TerminalKey.arrowLeft,
      TerminalExtraKey.arrowDown => TerminalKey.arrowDown,
      TerminalExtraKey.arrowRight => TerminalKey.arrowRight,
      TerminalExtraKey.pageDown => TerminalKey.pageDown,
      TerminalExtraKey.control || TerminalExtraKey.alt => null,
    };
    if (terminalKey == null) return;
    terminal.keyInput(
      terminalKey,
      shift: key == TerminalExtraKey.pipe || key == TerminalExtraKey.tilde,
    );
  }

  void insertText(String text) {
    if (text.isEmpty) return;
    terminal.paste(text);
  }

  void runCommand(String command) {
    terminal.paste(command);
    _bypassModifiers = true;
    try {
      terminal.keyInput(TerminalKey.enter);
    } finally {
      _bypassModifiers = false;
    }
  }

  void clear() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingOutput.clear();
    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
  }

  TerminalModifierState _nextModifierState(
    TerminalModifierState current, {
    required bool lock,
  }) {
    if (lock) {
      return current == TerminalModifierState.locked
          ? TerminalModifierState.inactive
          : TerminalModifierState.locked;
    }
    return current == TerminalModifierState.inactive
        ? TerminalModifierState.oneShot
        : TerminalModifierState.inactive;
  }

  String? _handleInput(TerminalKeyboardEvent event) {
    if (_bypassModifiers) return defaultInputHandler(event);
    final controlActive = _controlState != TerminalModifierState.inactive;
    final altActive = _altState != TerminalModifierState.inactive;
    final output = defaultInputHandler(
      event.copyWith(
        ctrl: event.ctrl || controlActive,
        alt: event.alt || altActive,
      ),
    );
    if (output != null) _consumeOneShotModifiers();
    return output;
  }

  void _consumeOneShotModifiers() {
    var changed = false;
    if (_controlState == TerminalModifierState.oneShot) {
      _controlState = TerminalModifierState.inactive;
      changed = true;
    }
    if (_altState == TerminalModifierState.oneShot) {
      _altState = TerminalModifierState.inactive;
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  void _sendOutput(String data) {
    try {
      _session.sendText(data);
    } on Object catch (error) {
      onInputError?.call(error);
    }
  }

  void _resize(int width, int height, int pixelWidth, int pixelHeight) {
    _session.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  void _queueOutput(String data) {
    if (_disposed || data.isEmpty) return;
    _pendingOutput.write(data);
    _flushTimer ??= Timer(_flushInterval, _flushOutput);
  }

  void _flushOutput() {
    _flushTimer = null;
    if (_disposed) return;
    final data = _pendingOutput.toString();
    _pendingOutput.clear();
    if (data.isNotEmpty) terminal.write(data);
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingOutput.clear();
    terminal.onOutput = null;
    terminal.onResize = null;
    unawaited(_outputSubscription.cancel());
    super.dispose();
  }
}

class _ModifierInputHandler implements TerminalInputHandler {
  const _ModifierInputHandler(this.adapter);

  final TerminalSessionAdapter adapter;

  @override
  String? call(TerminalKeyboardEvent event) => adapter._handleInput(event);
}
