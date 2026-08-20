import 'dart:async';

import 'package:xterm/xterm.dart';

import '../../../app/models.dart';
import '../../../core/ssh/ssh_models.dart';
import '../../../core/ssh/ssh_session_controller.dart';
import '../../../core/terminal/terminal_session_adapter.dart';
import '../application/tool_output.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_runtime_bridges.dart';
import '../domain/agent_tool.dart';

/// Terminal access for the agent, implemented over the real SSH session.
///
/// Reads come from the xterm buffer the user is looking at. Writes are only
/// possible through [runApprovedCommand], which pastes the approved text
/// verbatim into the interactive shell — exactly what the user saw and
/// approved, with nothing appended, so no exit-code sentinel exists.
class AgentTerminalRuntime implements AgentTerminalBridge {
  AgentTerminalRuntime({
    required HostProfile host,
    required SshSessionController session,
    required TerminalSessionAdapter adapter,
  }) : _host = host,
       _session = session,
       _adapter = adapter;

  /// Quiet period that ends output capture. Long enough for a shell to finish
  /// printing a prompt, short enough that a read-only command feels immediate.
  static const _idleWindow = Duration(milliseconds: 900);

  /// Grace period for the very first byte, for commands that think first.
  static const _firstOutputWindow = Duration(seconds: 15);

  static const _maxCaptureBytes = 256 * 1024;

  final HostProfile _host;
  final SshSessionController _session;
  final TerminalSessionAdapter _adapter;

  bool _running = false;

  @override
  AgentSessionInfo describeSession() {
    final terminal = _adapter.terminal;
    return AgentSessionInfo(
      hostId: _host.id,
      label: '${_host.username}@${_host.host}:${_host.port}',
      host: _host.host,
      port: _host.port,
      username: _host.username,
      connectionState: _describeState(_session.state),
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
      failureMessage: _session.failure?.message,
    );
  }

  @override
  AgentTerminalSnapshot snapshot({required int scrollbackLines}) {
    final terminal = _adapter.terminal;
    final lines = terminal.lines;
    final total = lines.length;
    final rows = terminal.viewHeight;
    final visibleStart = (total - rows).clamp(0, total);
    final scrollbackStart = (visibleStart - scrollbackLines).clamp(
      0,
      visibleStart,
    );
    return AgentTerminalSnapshot(
      visible: _readLines(terminal, visibleStart, total),
      scrollback: _readLines(terminal, scrollbackStart, visibleStart),
      currentInput: _adapter.pendingInput,
      columns: terminal.viewWidth,
      rows: rows,
    );
  }

  @override
  Future<AgentShellExecution> runApprovedCommand(
    String command, {
    required AgentCancellationToken cancellation,
    required Duration timeout,
  }) async {
    cancellation.throwIfCancelled();
    if (!_session.isConnected) {
      throw const AgentToolException('SSH 会话未连接，命令没有执行。');
    }
    if (_running) {
      throw const AgentToolException('上一条已批准的命令还在执行，请等它结束。');
    }
    _running = true;
    final buffer = StringBuffer();
    final completer = Completer<void>();
    final startedAt = DateTime.now();
    var truncated = false;
    var timedOut = false;
    var cancelled = false;
    Timer? idleTimer;
    Timer? overallTimer;

    void finish() {
      if (!completer.isCompleted) completer.complete();
    }

    void restartIdleTimer(Duration window) {
      idleTimer?.cancel();
      idleTimer = Timer(window, finish);
    }

    final subscription = _session.output.listen((data) {
      if (buffer.length >= _maxCaptureBytes) {
        truncated = true;
      } else {
        buffer.write(data);
      }
      restartIdleTimer(_idleWindow);
    }, onDone: finish);
    cancellation.addListener(() {
      cancelled = true;
      finish();
    });
    overallTimer = Timer(timeout, () {
      timedOut = true;
      finish();
    });
    restartIdleTimer(_firstOutputWindow);

    try {
      _adapter.runCommand(command);
      await completer.future;
    } finally {
      idleTimer?.cancel();
      overallTimer.cancel();
      await subscription.cancel();
      _running = false;
    }

    if (cancelled) {
      throw const AgentFailure(
        stage: AgentFailureStage.cancelled,
        message: '用户停止了本轮运行。',
      );
    }
    if (!_session.isConnected) {
      throw const AgentToolException('命令执行期间 SSH 会话断开，输出可能不完整。');
    }
    final output = ToolOutput.trimTrailingBlankLines(
      ToolOutput.sanitizeTerminal(buffer.toString()),
    );
    return AgentShellExecution(
      command: command,
      output: truncated ? '$output\n[输出超过采集上限，已截断]' : output,
      duration: DateTime.now().difference(startedAt),
      timedOut: timedOut,
    );
  }

  static String _readLines(Terminal terminal, int start, int end) {
    if (end <= start) return '';
    final lines = terminal.lines;
    final buffer = StringBuffer();
    for (var index = start; index < end; index++) {
      buffer.writeln(lines[index].getText().trimRight());
    }
    return buffer.toString();
  }

  static String _describeState(SshConnectionState state) {
    return switch (state) {
      SshConnectionState.idle => 'idle',
      SshConnectionState.connecting => 'connecting',
      SshConnectionState.awaitingHostTrust => 'awaiting-host-trust',
      SshConnectionState.authenticating => 'authenticating',
      SshConnectionState.connected => 'connected',
      SshConnectionState.reconnecting => 'reconnecting',
      SshConnectionState.disconnected => 'disconnected',
      SshConnectionState.failed => 'failed',
    };
  }
}
