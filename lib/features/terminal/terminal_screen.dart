import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/ssh/ssh_connection_factory.dart';
import '../../core/ssh/ssh_models.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/terminal/terminal_input.dart';
import '../../core/terminal/terminal_session_adapter.dart';
import '../history/history_repository.dart';
import '../snippets/snippet_repository.dart';
import '../sftp/sftp_transfer_controller.dart';
import '../sftp/sftp_drawer.dart';
import '../../ui/shelly_icon_button.dart';
import 'agent_panel.dart';
import 'extra_keys_bar.dart';
import 'terminal_drawers.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.server,
    required this.connectionFactory,
    required this.keepAlive,
    required this.fontSize,
    required this.cursorBlink,
    required this.extraKeys,
    required this.snippets,
    required this.history,
    super.key,
  });

  final HostProfile server;
  final SshConnectionFactory connectionFactory;
  final bool keepAlive;
  final double fontSize;
  final bool cursorBlink;
  final List<TerminalExtraKey> extraKeys;
  final SnippetRepository snippets;
  final HistoryRepository history;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with TickerProviderStateMixin {
  final _terminalFocus = FocusNode();
  late final TerminalController _terminalController;
  late final SshSessionController _session;
  late final TerminalSessionAdapter _terminal;
  late final SftpTransferController _transfers;
  bool _menuOpen = false;
  bool _agentOpen = false;
  bool _agentInputFocused = false;
  final String _historySessionId = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    _terminalController = TerminalController(vsync: this);
    _session = SshSessionController(
      host: widget.server,
      factory: widget.connectionFactory,
      promptForHostTrust: _promptForHostKey,
      keepAlive: widget.keepAlive,
    )..addListener(_onSessionChanged);
    _terminal = TerminalSessionAdapter(
      session: _session,
      onInputError: _handleTerminalInputError,
      onCommandSubmitted: _recordCommand,
    )..addListener(_onTerminalChanged);
    _transfers = SftpTransferController(sshSession: _session);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_session.connect());
    });
  }

  @override
  void dispose() {
    _terminal
      ..removeListener(_onTerminalChanged)
      ..dispose();
    _transfers.dispose();
    _session
      ..removeListener(_onSessionChanged)
      ..dispose();
    _terminalController.dispose();
    _terminalFocus.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_session.isConnected && !_agentInputFocused) {
      _terminalFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(context),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final half = constraints.maxHeight / 2;
                        return Stack(
                          children: [
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 300),
                              curve: const Cubic(0.22, 0.9, 0.3, 1),
                              left: 0,
                              top: 0,
                              right: 0,
                              bottom: _agentOpen ? half : 0,
                              child: _buildTerminal(context),
                            ),
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 300),
                              curve: const Cubic(0.22, 0.9, 0.3, 1),
                              left: 0,
                              right: 0,
                              height: half,
                              bottom: _agentOpen ? 0 : -half,
                              child: AgentPanel(
                                onClose: _closeAgent,
                                onCommandRequested: _requestCommand,
                                onInputFocusChanged: (value) =>
                                    setState(() => _agentInputFocused = value),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              if (_menuOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _menuOpen = false),
                  ),
                ),
                Positioned(top: 56, right: 8, child: _buildMenu(context)),
              ],
            ],
          ),
        ),
        backgroundColor: colors.background,
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.shelly;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 4),
          ShellyIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: '断开连接',
            onPressed: _requestExit,
          ),
          Expanded(
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: _connectionColor(colors).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: _connectionColor(colors),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.server.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _connectionLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurface3,
                          fontSize: 9.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ShellyIconButton(
            icon: Icons.folder_rounded,
            tooltip: '文件',
            onPressed: !_session.isConnected
                ? null
                : () {
                    setState(() => _menuOpen = false);
                    showFilesDrawer(
                      context,
                      widget.server,
                      session: _session,
                      transfers: _transfers,
                    );
                  },
          ),
          ShellyIconButton(
            icon: _menuOpen ? Icons.close_rounded : Icons.menu_rounded,
            tooltip: '功能',
            active: _menuOpen,
            onPressed: !_session.isConnected
                ? null
                : () => setState(() => _menuOpen = !_menuOpen),
          ),
          const SizedBox(width: 3),
        ],
      ),
    );
  }

  Widget _buildTerminal(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.background,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: TerminalView(
                  _terminal.terminal,
                  controller: _terminalController,
                  focusNode: _terminalFocus,
                  autofocus: false,
                  readOnly: !_session.isConnected || _agentInputFocused,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  textStyle: TerminalStyle(
                    fontSize: widget.fontSize,
                    height: 1.25,
                  ),
                  theme: _terminalTheme(colors),
                  cursorBlink: widget.cursorBlink,
                  deleteDetection: true,
                  enableSuggestions: true,
                  keyboardType: TextInputType.text,
                  backgroundOpacity: 0,
                  hideScrollBar: true,
                  onCopied: _onTerminalCopied,
                  onPaste: _pasteClipboard,
                ),
              ),
              if (_session.isConnected && !_agentInputFocused)
                ExtraKeysBar(
                  keys: widget.extraKeys,
                  controlState: _terminal.controlState,
                  altState: _terminal.altState,
                  onKey: _handleExtraKey,
                  onModifierLongPress: _lockModifier,
                ),
            ],
          ),
          if (!_session.isConnected)
            Positioned.fill(child: _buildConnectionState(context)),
        ],
      ),
    );
  }

  Widget _buildConnectionState(BuildContext context) {
    final colors = context.shelly;
    final state = _session.state;
    final failure = _session.failure;
    final waiting =
        state == SshConnectionState.connecting ||
        state == SshConnectionState.reconnecting ||
        state == SshConnectionState.authenticating ||
        state == SshConnectionState.awaitingHostTrust;
    return ColoredBox(
      color: colors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (waiting)
                const SizedBox.square(
                  dimension: 30,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                Icon(
                  state == SshConnectionState.failed
                      ? Icons.error_outline_rounded
                      : Icons.link_off_rounded,
                  size: 32,
                  color: _connectionColor(colors),
                ),
              const SizedBox(height: 16),
              Text(
                _connectionTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                failure?.message ??
                    '${widget.server.host}:${widget.server.port} · ${widget.server.username}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurface3,
                  fontFamily: failure == null ? 'monospace' : null,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
              if (failure != null) ...[
                const SizedBox(height: 5),
                Text(
                  _failureStageLabel(failure.stage),
                  style: TextStyle(color: colors.onSurface3, fontSize: 10),
                ),
              ],
              if (state == SshConnectionState.failed ||
                  state == SshConnectionState.disconnected) ...[
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: _requestExit,
                      child: const Text('返回'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _connectionColor(ShellyColors colors) {
    return switch (_session.state) {
      SshConnectionState.connected => colors.primary,
      SshConnectionState.failed => Theme.of(context).colorScheme.error,
      SshConnectionState.disconnected => colors.onSurface3,
      _ => colors.onSurface2,
    };
  }

  TerminalTheme _terminalTheme(ShellyColors colors) {
    return TerminalTheme(
      cursor: colors.primary,
      selectionCursor: colors.background,
      selection: colors.primary.withValues(alpha: 0.28),
      foreground: colors.terminalOutput,
      background: colors.background,
      black: const Color(0xFF202124),
      red: const Color(0xFFC63C47),
      green: const Color(0xFF3D9A57),
      yellow: const Color(0xFFC19328),
      blue: const Color(0xFF3976C5),
      magenta: const Color(0xFF9A52B8),
      cyan: const Color(0xFF258C9B),
      white: const Color(0xFFD9D9D6),
      brightBlack: const Color(0xFF77797C),
      brightRed: const Color(0xFFE35D65),
      brightGreen: const Color(0xFF65B778),
      brightYellow: const Color(0xFFD9B44A),
      brightBlue: const Color(0xFF6598DD),
      brightMagenta: const Color(0xFFB879CF),
      brightCyan: const Color(0xFF59AAB5),
      brightWhite: const Color(0xFFF2F2EF),
      searchHitBackground: const Color(0xFFE0B94C),
      searchHitBackgroundCurrent: const Color(0xFF65B778),
      searchHitForeground: const Color(0xFF111111),
    );
  }

  String get _connectionLabel => switch (_session.state) {
    SshConnectionState.idle => '等待连接',
    SshConnectionState.connecting => '正在连接',
    SshConnectionState.awaitingHostTrust => '等待指纹确认',
    SshConnectionState.authenticating => '正在认证',
    SshConnectionState.connected => '已连接',
    SshConnectionState.reconnecting => '正在重连',
    SshConnectionState.disconnected => '已断开',
    SshConnectionState.failed => '连接失败',
  };

  String get _connectionTitle => switch (_session.state) {
    SshConnectionState.idle => '准备连接',
    SshConnectionState.connecting => '正在建立 TCP/SSH 连接',
    SshConnectionState.awaitingHostTrust => '等待你确认主机指纹',
    SshConnectionState.authenticating => '正在验证认证资料',
    SshConnectionState.connected => '已连接',
    SshConnectionState.reconnecting => '正在重新连接',
    SshConnectionState.disconnected => 'SSH 会话已断开',
    SshConnectionState.failed => '无法连接到设备',
  };

  String _failureStageLabel(SshFailureStage stage) => switch (stage) {
    SshFailureStage.credential => '认证资料',
    SshFailureStage.dns => 'DNS 解析',
    SshFailureStage.connect => '网络连接',
    SshFailureStage.handshake => 'SSH 握手',
    SshFailureStage.hostKey => '主机密钥',
    SshFailureStage.authentication => '用户认证',
    SshFailureStage.shell => '远程 shell',
    SshFailureStage.session => 'SSH 会话',
  };

  Future<bool> _promptForHostKey(HostKeyChallenge challenge) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope<void>(
            canPop: false,
            child: AlertDialog(
              title: Text(challenge.isChanged ? '主机密钥已变化' : '确认主机指纹'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${challenge.host}:${challenge.port}'),
                    const SizedBox(height: 14),
                    Text(
                      '算法',
                      style: TextStyle(
                        color: context.shelly.onSurface3,
                        fontSize: 11,
                      ),
                    ),
                    SelectableText(
                      challenge.algorithm,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (challenge.previousFingerprint != null) ...[
                      Text(
                        '已保存的 SHA256 指纹',
                        style: TextStyle(
                          color: context.shelly.onSurface3,
                          fontSize: 11,
                        ),
                      ),
                      SelectableText(
                        challenge.previousFingerprint!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      challenge.isChanged ? '服务器当前提供的 SHA256 指纹' : 'SHA256 指纹',
                      style: TextStyle(
                        color: context.shelly.onSurface3,
                        fontSize: 11,
                      ),
                    ),
                    SelectableText(
                      challenge.fingerprint,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      challenge.isChanged
                          ? '连接已阻止。请先通过可信渠道核对新指纹，再返回设置删除旧记录。'
                          : '请通过可信渠道核对指纹。接受后，该算法的指纹会保存到本机。',
                      style: TextStyle(
                        color: challenge.isChanged
                            ? Theme.of(context).colorScheme.error
                            : context.shelly.onSurface2,
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              actions: challenge.isChanged
                  ? [
                      FilledButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('阻止连接'),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('拒绝'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('信任并继续'),
                      ),
                    ],
            ),
          ),
        ) ??
        false;
  }

  Widget _buildMenu(BuildContext context) {
    final colors = context.shelly;
    final items = [
      (Icons.smart_toy_outlined, 'Agent', _agentOpen, _toggleAgent),
      (Icons.speed_rounded, '状态', false, () => _showStatus(context)),
      (
        Icons.notes_rounded,
        '便签',
        false,
        () => showSnippetsDrawer(
          context,
          onInsert: _insertCommand,
          onRun: _confirmAndRunCommand,
          repository: widget.snippets,
          hostId: widget.server.id,
        ),
      ),
      (
        Icons.history_rounded,
        '历史',
        false,
        () => showHistoryDrawer(
          context,
          onInsert: _insertCommand,
          onRun: _confirmAndRunCommand,
          repository: widget.history,
          snippets: widget.snippets,
          hostId: widget.server.id,
        ),
      ),
    ];
    return Material(
      color: colors.elevated,
      elevation: 14,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 176,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                Material(
                  color: item.$3 ? colors.surface3 : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      setState(() => _menuOpen = false);
                      item.$4();
                    },
                    child: SizedBox(
                      height: 44,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(
                              item.$1,
                              size: 18,
                              color: item.$3
                                  ? colors.onSurface
                                  : colors.onSurface2,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              item.$2,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            if (item.$3)
                              const Icon(Icons.check_rounded, size: 15),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleAgent() {
    setState(() => _agentOpen = !_agentOpen);
    if (!_agentOpen) _terminalFocus.requestFocus();
  }

  void _closeAgent({bool restoreTerminalFocus = true}) {
    setState(() {
      _agentOpen = false;
      _agentInputFocused = false;
    });
    if (restoreTerminalFocus) _terminalFocus.requestFocus();
  }

  void _insertCommand(String command) {
    if (!_session.isConnected) return;
    _terminal.insertText(command);
    _terminalFocus.requestFocus();
  }

  void _runCommand(String command) {
    if (!_session.isConnected) return;
    _terminal.runCommand(command);
    _terminalFocus.requestFocus();
  }

  void _recordCommand(String command) {
    unawaited(_persistCommand(command));
  }

  Future<void> _persistCommand(String command) async {
    try {
      await widget.history.record(
        hostId: widget.server.id,
        sessionId: _historySessionId,
        command: command,
      );
    } on HistoryRepositoryException catch (error) {
      if (mounted) _message(error.message);
    }
  }

  Future<void> _confirmAndRunCommand(String command) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('运行命令？'),
        content: SelectableText(
          command,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('运行'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) _runCommand(command);
  }

  Future<void> _requestExit() async {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    if (_agentOpen) {
      _closeAgent(restoreTerminalFocus: false);
      return;
    }
    if (!_session.isConnected) {
      await _session.disconnect();
      if (mounted) Navigator.pop(context);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开 SSH 连接？'),
        content: const Text('当前远程 shell 将被关闭。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _session.disconnect();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _requestCommand(String command) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Agent 申请命令',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.shelly.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            command,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    if (approved == true) _runCommand(command);
  }

  void _handleExtraKey(TerminalExtraKey key) {
    if (!_session.isConnected || _agentInputFocused) return;
    if (key.isModifier) {
      _terminal.toggleModifier(key, lock: false);
    } else {
      _terminal.sendKey(key);
    }
    _terminalFocus.requestFocus();
  }

  void _lockModifier(TerminalExtraKey key) {
    if (!_session.isConnected || _agentInputFocused || !key.isModifier) return;
    _terminal.toggleModifier(key, lock: true);
    _terminalFocus.requestFocus();
  }

  void _retry() {
    _terminal.clear();
    unawaited(_session.retry());
  }

  void _handleTerminalInputError(Object error) {
    if (!mounted) return;
    if (error is SshFailure) {
      _message(error.message);
    } else if (error is StateError) {
      _message('SSH 会话已经关闭。');
    } else {
      _message('向远程终端发送输入失败。');
    }
  }

  void _onTerminalCopied() {
    _terminalController.clearSelection();
    _message('已复制');
  }

  void _pasteClipboard() {
    unawaited(_pasteClipboardText());
  }

  Future<void> _pasteClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || !_session.isConnected || _agentInputFocused) return;
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _terminal.insertText(text);
    _terminalController.clearSelection();
    _terminalFocus.requestFocus();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

Future<void> _showStatus(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _StatusDialog(),
  );
}

class _StatusDialog extends StatelessWidget {
  const _StatusDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.all(20),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: context.shelly.surface3,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.speed_rounded,
                  size: 20,
                  color: context.shelly.onSurface2,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'prod-web-01',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '45.77.89.12:22',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const _Stat(label: 'CPU', value: 0.46),
          const _Stat(label: '内存', value: 0.68),
          const _Stat(label: '磁盘', value: 0.45),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '运行 12 天 4 小时',
                style: TextStyle(
                  color: context.shelly.onSurface3,
                  fontSize: 10.5,
                ),
              ),
              Text(
                '延迟 23 ms',
                style: TextStyle(
                  color: context.shelly.onSurface3,
                  fontFamily: 'monospace',
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final double value;

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
                '${(value * 100).round()}%',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: context.shelly.surface3,
              color: context.shelly.primary,
            ),
          ),
        ],
      ),
    );
  }
}
