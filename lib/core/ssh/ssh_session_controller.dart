import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app/models.dart';
import '../../features/sftp/sftp_session.dart';
import '../diagnostics/app_log.dart';
import '../retry/backoff_policy.dart';
import 'ssh_connection_event.dart';
import 'ssh_connection_factory.dart';
import 'ssh_health_monitor.dart';
import 'ssh_models.dart';

/// How a connection attempt was started, which decides the state shown while it
/// runs and what happens when it fails.
enum _ConnectMode { initial, manualRetry, autoReconnect }

class SshSessionController extends ChangeNotifier {
  SshSessionController({
    required HostProfile host,
    required SshConnectionFactory factory,
    required HostTrustPrompt promptForHostTrust,
    required bool keepAlive,
    required bool autoReconnect,
  }) : _host = host,
       _factory = factory,
       _promptForHostTrust = promptForHostTrust,
       _keepAlive = keepAlive,
       _autoReconnect = autoReconnect;

  static const _logTag = 'ssh';

  /// Browse channel + two transfer channels + the agent's channel, plus one
  /// spare. Kept well below OpenSSH's default `MaxSessions 10`, which also has
  /// to fit the interactive shell and status commands.
  static const maxSftpChannels = 5;

  static const _sftpCloseTimeout = Duration(seconds: 5);

  /// Bounds opening an SFTP channel: some servers accept the request and then
  /// never answer.
  static const _sftpOpenTimeout = Duration(seconds: 15);

  /// First retry after ~1s, then 2s, 4s, 8s, each with ±20% jitter.
  static const _reconnectPolicy = BackoffPolicy(
    maxRetries: 4,
    baseDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 8),
  );

  final HostProfile _host;
  final SshConnectionFactory _factory;
  final HostTrustPrompt _promptForHostTrust;
  final bool _keepAlive;
  final bool _autoReconnect;
  final StreamController<String> _outputController =
      StreamController<String>.broadcast(sync: true);
  final SshConnectionEventLog _events = SshConnectionEventLog();

  late final SshHealthMonitor _health = SshHealthMonitor(
    probe: _probeConnection,
    onProbeFailed: _handleProbeFailure,
    onProbeRecovered: _handleProbeRecovery,
    onLinkLost: _handleProbeLinkLoss,
  );

  SshConnectionState _state = SshConnectionState.idle;
  SshFailure? _failure;
  SshCancellationToken? _cancellationToken;
  SshConnectionHandle? _connection;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<void>? _stdoutDone;
  Future<void>? _stderrDone;
  final Set<SftpSession> _sftpSessions = {};
  SftpSession? _browseSftp;
  Future<SftpSession>? _browseSftpPending;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _everConnected = false;
  int _terminalWidth = 80;
  int _terminalHeight = 24;
  int _terminalPixelWidth = 0;
  int _terminalPixelHeight = 0;
  int _appliedWidth = 0;
  int _appliedHeight = 0;
  int _appliedPixelWidth = 0;
  int _appliedPixelHeight = 0;
  bool _resizePending = false;
  bool _resizeWarned = false;
  int _generation = 0;
  bool _disposed = false;

  SshConnectionState get state => _state;
  SshFailure? get failure => _failure;
  Stream<String> get output => _outputController.stream;
  bool get isConnected => _state == SshConnectionState.connected;

  /// True while an automatic reconnect is pending or in flight.
  bool get isAutoReconnecting =>
      _reconnectAttempt > 0 && _state != SshConnectionState.connected;
  int get reconnectAttempt => _reconnectAttempt;
  int get maxReconnectAttempts => _reconnectPolicy.maxRetries;
  bool get autoReconnectEnabled => _autoReconnect;

  /// Oldest first; bounded, and free of command text and credentials.
  List<SshConnectionEvent> get connectionEvents => _events.events;

  /// SFTP channels currently open on this connection, browse channel included.
  int get openSftpChannels => _sftpSessions.length;

  Future<void> connect() => _startConnection(mode: _ConnectMode.initial);

  Future<void> retry() {
    _reconnectAttempt = 0;
    return _startConnection(mode: _ConnectMode.manualRetry);
  }

  /// Runs one liveness probe now.
  ///
  /// Called when the app returns to the foreground and when the file drawer's
  /// visibility changes — the two moments where a link can have died while
  /// nothing was watching.
  Future<void> checkHealth() async {
    if (!isConnected) return;
    await _health.check(immediate: true);
  }

  Future<void> _startConnection({required _ConnectMode mode}) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final generation = ++_generation;
    _cleanupConnection();
    _failure = null;
    final isRetry = mode != _ConnectMode.initial;
    _setState(
      isRetry ? SshConnectionState.reconnecting : SshConnectionState.connecting,
    );
    final token = SshCancellationToken();
    _cancellationToken = token;
    try {
      final connection = await _factory.connect(
        profile: _host,
        promptForHostTrust: _promptForHostTrust,
        onStateChanged: (state) {
          if (generation != _generation || token.isCancelled) return;
          if (isRetry && state == SshConnectionState.connecting) {
            _setState(SshConnectionState.reconnecting);
          } else {
            _setState(state);
          }
        },
        cancellationToken: token,
        terminalSize: SshTerminalSize(
          width: _terminalWidth,
          height: _terminalHeight,
          pixelWidth: _terminalPixelWidth,
          pixelHeight: _terminalPixelHeight,
        ),
      );
      if (generation != _generation || token.isCancelled || _disposed) {
        connection.close();
        return;
      }
      _connection = connection;
      // The PTY was already created at this size, so a failure here is cosmetic
      // and is retried by `_flushTerminalSize` rather than failing the session.
      _appliedWidth = _terminalWidth;
      _appliedHeight = _terminalHeight;
      _appliedPixelWidth = _terminalPixelWidth;
      _appliedPixelHeight = _terminalPixelHeight;
      _resizePending = false;
      _listenToOutput(connection, generation);
      _setState(SshConnectionState.connected);
      _everConnected = true;
      if (_reconnectAttempt > 0) {
        _record(
          SshConnectionEventKind.reconnect,
          '第 $_reconnectAttempt 次自动重连成功',
        );
        _emitNotice('已重新连接。');
        _reconnectAttempt = 0;
      }
      if (_keepAlive) _health.start();
      unawaited(
        connection.done.then(
          (_) => _handleRemoteClose(generation),
          onError: (Object error, StackTrace stackTrace) {
            _handleRemoteError(error, generation);
          },
        ),
      );
    } on SshConnectionCancelled {
      if (generation == _generation && !_disposed) {
        if (identical(_cancellationToken, token)) _cancellationToken = null;
        _reconnectAttempt = 0;
        _setState(SshConnectionState.disconnected);
      }
    } on SshFailure catch (failure) {
      if (generation != _generation || _disposed) return;
      if (identical(_cancellationToken, token)) _cancellationToken = null;
      AppLog.instance.warning(
        _logTag,
        'connect failed at ${failure.stage.name}',
        error: failure.cause ?? failure,
      );
      if (mode == _ConnectMode.autoReconnect) {
        _scheduleReconnect(failure);
      } else {
        _enterFailed(failure);
      }
    }
  }

  void sendText(String text) {
    final connection = _connection;
    if (!isConnected || connection == null) {
      throw SshFailure(
        stage: SshFailureStage.session,
        host: _host.host,
        port: _host.port,
        message: 'SSH 会话尚未连接。',
      );
    }
    try {
      connection.write(Uint8List.fromList(utf8.encode(text)));
    } on Object catch (error) {
      // A rejected write is reported to the caller, but it does not tear down
      // the session on its own: only a real transport close does that. The
      // probe below decides whether the link is actually gone.
      AppLog.instance.warning(_logTag, 'terminal write failed', error: error);
      _record(
        SshConnectionEventKind.warning,
        '向远程终端发送输入失败，已触发连接检查',
        error: error,
      );
      unawaited(_health.check(immediate: true));
      rethrow;
    }
  }

  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    if (width <= 0 || height <= 0 || pixelWidth < 0 || pixelHeight < 0) return;
    _terminalWidth = width;
    _terminalHeight = height;
    _terminalPixelWidth = pixelWidth;
    _terminalPixelHeight = pixelHeight;
    _flushTerminalSize();
  }

  /// Pushes the desired terminal size to the remote PTY, remembering it for a
  /// later attempt if the channel refuses right now.
  ///
  /// The file drawer, the soft keyboard and rotation all resize, so a single
  /// failed resize must never be escalated into a disconnect.
  void _flushTerminalSize() {
    final connection = _connection;
    if (!isConnected || connection == null) {
      _resizePending = true;
      return;
    }
    if (!_resizePending &&
        _appliedWidth == _terminalWidth &&
        _appliedHeight == _terminalHeight &&
        _appliedPixelWidth == _terminalPixelWidth &&
        _appliedPixelHeight == _terminalPixelHeight) {
      return;
    }
    try {
      connection.resizeTerminal(
        _terminalWidth,
        _terminalHeight,
        _terminalPixelWidth,
        _terminalPixelHeight,
      );
      _appliedWidth = _terminalWidth;
      _appliedHeight = _terminalHeight;
      _appliedPixelWidth = _terminalPixelWidth;
      _appliedPixelHeight = _terminalPixelHeight;
      _resizePending = false;
      if (_resizeWarned) {
        _resizeWarned = false;
        _record(SshConnectionEventKind.warning, '远程终端尺寸已补发成功');
      }
    } on Object catch (error) {
      _resizePending = true;
      if (!_resizeWarned) {
        _resizeWarned = true;
        AppLog.instance.warning(
          _logTag,
          'resize terminal failed, will retry later',
          error: error,
        );
        _record(
          SshConnectionEventKind.warning,
          '调整远程终端尺寸失败，将在下次尺寸变化或重连后补发',
          error: error,
        );
      }
      unawaited(_health.check(immediate: true));
    }
  }

  /// The single SFTP channel used for browsing.
  ///
  /// Reused across every drawer open: closing the drawer must not close the
  /// channel, or repeated opens exhaust the server's `MaxSessions`.
  Future<SftpSession> openBrowseSftpSession() {
    final existing = _browseSftp;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    final pending = _browseSftpPending;
    if (pending != null) return pending;
    final future = _openSftpSession(shared: true);
    _browseSftpPending = future;
    return future.whenComplete(() {
      if (identical(_browseSftpPending, future)) _browseSftpPending = null;
    });
  }

  /// A dedicated SFTP channel, for transfers and the agent runtime.
  Future<SftpSession> openSftpSession() => _openSftpSession(shared: false);

  /// Closes an SFTP channel, bounded and with the failure recorded rather than
  /// dropped on the floor.
  Future<void> closeSftpSession(SftpSession session) async {
    try {
      await session.close().timeout(_sftpCloseTimeout);
    } on Object catch (error) {
      AppLog.instance.warning(
        _logTag,
        'SFTP channel close failed',
        error: error,
      );
      _record(SshConnectionEventKind.channel, '关闭 SFTP 通道失败', error: error);
    }
  }

  Future<SftpSession> _openSftpSession({required bool shared}) async {
    final connection = _connection;
    final generation = _generation;
    if (!isConnected || connection == null) {
      throw SftpFailure('SSH 会话尚未连接。', path: '.');
    }
    if (_sftpSessions.length >= maxSftpChannels) {
      AppLog.instance.warning(
        _logTag,
        'SFTP channel limit reached (${_sftpSessions.length})',
      );
      _record(
        SshConnectionEventKind.channel,
        'SFTP 通道已达上限 $maxSftpChannels，拒绝新开通道',
      );
      throw SftpFailure(
        'SFTP 通道数量已达上限（$maxSftpChannels 个），请等待当前传输完成后重试。',
        path: '.',
      );
    }
    SftpSession? opened;
    final opening = connection.openSftp(
      onClosed: () {
        final session = opened;
        if (session != null) _releaseSftpSession(session);
      },
    );
    try {
      // A server that accepts the channel and then says nothing would otherwise
      // leave the drawer spinning forever.
      opened = await opening.timeout(_sftpOpenTimeout);
    } on TimeoutException catch (error) {
      // The channel can still open after we stop waiting; close it when it does,
      // so it does not sit in the server's session count for nothing.
      unawaited(
        opening.then(
          closeSftpSession,
          onError: (Object error, StackTrace stackTrace) {
            AppLog.instance.warning(
              _logTag,
              'abandoned SFTP channel failed to open',
              error: error,
            );
          },
        ),
      );
      AppLog.instance.warning(_logTag, 'SFTP open timed out', error: error);
      _record(SshConnectionEventKind.channel, '打开 SFTP 通道超时', error: error);
      throw SftpFailure('打开 SFTP 通道超时，请检查连接后重试。', path: '.', cause: error);
    } on Object catch (error) {
      if (error is SftpFailure) rethrow;
      throw SftpFailure(
        '无法创建 SFTP 会话，请确认服务器已启用 SFTP。',
        path: '.',
        cause: error,
      );
    }
    final session = opened;
    if (generation != _generation || !isConnected || _disposed) {
      await closeSftpSession(session);
      throw SftpFailure('SSH 会话已经断开。', path: '.');
    }
    _sftpSessions.add(session);
    if (shared) _browseSftp = session;
    _record(
      SshConnectionEventKind.channel,
      shared
          ? '打开共享 SFTP 浏览通道（当前 ${_sftpSessions.length}/$maxSftpChannels）'
          : '打开独立 SFTP 通道（当前 ${_sftpSessions.length}/$maxSftpChannels）',
    );
    return session;
  }

  void _releaseSftpSession(SftpSession session) {
    _sftpSessions.remove(session);
    if (identical(_browseSftp, session)) _browseSftp = null;
  }

  Future<SshCommandHandle> executeCommand(String command) async {
    final connection = _connection;
    final generation = _generation;
    if (!isConnected || connection == null) {
      throw SshFailure(
        stage: SshFailureStage.session,
        host: _host.host,
        port: _host.port,
        message: 'SSH 会话尚未连接。',
      );
    }
    late SshCommandHandle handle;
    try {
      handle = await connection.execute(command);
    } on Object catch (error) {
      throw SshFailure(
        stage: SshFailureStage.session,
        host: _host.host,
        port: _host.port,
        message: '无法创建远程命令通道。',
        cause: error,
      );
    }
    if (generation != _generation || !isConnected || _disposed) {
      handle.close();
      throw SshFailure(
        stage: SshFailureStage.session,
        host: _host.host,
        port: _host.port,
        message: 'SSH 会话已经断开。',
      );
    }
    return handle;
  }

  Future<void> disconnect() async {
    ++_generation;
    _reconnectAttempt = 0;
    _cleanupConnection();
    _failure = null;
    _record(SshConnectionEventKind.state, '用户主动断开连接');
    _setState(SshConnectionState.disconnected);
  }

  Future<void> _probeConnection() async {
    final connection = _connection;
    if (connection == null || connection.isClosed) {
      throw StateError('SSH connection is closed');
    }
    await connection.ping();
  }

  void _handleProbeFailure(Object error, int consecutiveFailures) {
    AppLog.instance.warning(
      _logTag,
      'SSH keep-alive failed (consecutive: $consecutiveFailures)',
      error: error,
    );
    _record(
      SshConnectionEventKind.health,
      '心跳探测失败（连续 $consecutiveFailures 次）',
      error: error,
    );
  }

  void _handleProbeRecovery(int recoveredAfterFailures) {
    AppLog.instance.info(
      _logTag,
      'SSH keep-alive recovered after $recoveredAfterFailures failure(s)',
    );
    _record(
      SshConnectionEventKind.health,
      '心跳探测在 $recoveredAfterFailures 次失败后恢复',
    );
  }

  void _handleProbeLinkLoss(Object error, bool immediate) {
    _handleLinkLoss(
      error,
      message: immediate ? '返回应用时检测到 SSH 连接已断开。' : 'SSH 心跳连续失败，连接已断开。',
    );
  }

  void _listenToOutput(SshConnectionHandle connection, int generation) {
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    _stdoutDone = stdoutDone.future;
    _stderrDone = stderrDone.future;
    _stdoutSubscription = connection.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) => _emitOutput(text, generation),
          onError: (Object error, StackTrace stackTrace) {
            _handleRemoteError(error, generation);
          },
          onDone: stdoutDone.complete,
        );
    _stderrSubscription = connection.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) => _emitOutput(text, generation),
          onError: (Object error, StackTrace stackTrace) {
            _handleRemoteError(error, generation);
          },
          onDone: stderrDone.complete,
        );
  }

  void _emitOutput(String text, int generation) {
    if (generation != _generation || _disposed || text.isEmpty) return;
    _outputController.add(text);
  }

  /// Writes a locally generated line into the terminal.
  ///
  /// Used only for reconnect notices, so the user can see what happened without
  /// the scrollback being cleared.
  void _emitNotice(String text) {
    if (_disposed || _outputController.isClosed) return;
    _outputController.add('\r\n\x1b[33m[Shelly] $text\x1b[0m\r\n');
  }

  Future<void> _handleRemoteClose(int generation) async {
    if (generation != _generation || _disposed) return;
    final outputDone = <Future<void>>[?_stdoutDone, ?_stderrDone];
    if (outputDone.isNotEmpty) {
      try {
        await Future.wait(
          outputDone,
        ).timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        // Some servers leave channel streams open after the client is done.
      }
    }
    if (generation != _generation || _disposed) return;
    ++_generation;
    _cleanupConnection();
    // A clean close is the remote shell exiting. Reconnecting here would fight
    // the user's own `exit`, so it stays a plain disconnect.
    AppLog.instance.info(_logTag, 'remote closed the session');
    _record(SshConnectionEventKind.state, '远端已正常关闭会话');
    _reconnectAttempt = 0;
    _setState(SshConnectionState.disconnected);
  }

  void _handleRemoteError(Object error, int generation) {
    if (generation != _generation || _disposed) return;
    _handleLinkLoss(error, message: 'SSH 链路异常，连接已中断。');
  }

  /// The transport is genuinely gone: clean up, then either start the automatic
  /// reconnect or land in a failed state with a reason.
  void _handleLinkLoss(Object error, {required String message}) {
    if (_disposed) return;
    final failure = SshFailure(
      stage: SshFailureStage.session,
      host: _host.host,
      port: _host.port,
      message: message,
      cause: error,
    );
    ++_generation;
    _cleanupConnection();
    AppLog.instance.warning(_logTag, message, error: error);
    _record(
      SshConnectionEventKind.failure,
      message,
      stage: SshFailureStage.session,
      error: error,
    );
    if (_canAutoReconnect(failure)) {
      _emitNotice('$message正在自动重连…');
      _scheduleReconnect(failure);
    } else {
      _enterFailed(failure);
    }
  }

  bool _canAutoReconnect(SshFailure failure) {
    if (!_autoReconnect || _disposed || !_everConnected) return false;
    if (_reconnectAttempt >= _reconnectPolicy.maxRetries) return false;
    return switch (failure.stage) {
      // Reusing the stored profile is fine, but a changed fingerprint, a bad
      // credential or a rejected login must never be retried in a loop.
      SshFailureStage.credential ||
      SshFailureStage.hostKey ||
      SshFailureStage.authentication => false,
      SshFailureStage.dns ||
      SshFailureStage.connect ||
      SshFailureStage.handshake ||
      SshFailureStage.shell ||
      SshFailureStage.session => true,
    };
  }

  void _scheduleReconnect(SshFailure failure) {
    if (!_canAutoReconnect(failure)) {
      _enterFailed(failure);
      return;
    }
    final attempt = ++_reconnectAttempt;
    final delay = _reconnectPolicy.delayFor(attempt);
    _failure = failure;
    AppLog.instance.info(
      _logTag,
      'auto reconnect $attempt/${_reconnectPolicy.maxRetries} in ${delay.inMilliseconds}ms',
    );
    _record(
      SshConnectionEventKind.reconnect,
      '第 $attempt/${_reconnectPolicy.maxRetries} 次自动重连将在 '
      '${(delay.inMilliseconds / 1000).toStringAsFixed(1)} 秒后开始',
      stage: failure.stage,
    );
    _setState(SshConnectionState.reconnecting);
    // The attempt counter is part of the UI even when the state does not change.
    _notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_disposed) return;
      unawaited(_startConnection(mode: _ConnectMode.autoReconnect));
    });
  }

  void _enterFailed(SshFailure failure) {
    final exhausted =
        _reconnectAttempt >= _reconnectPolicy.maxRetries &&
        _reconnectAttempt > 0;
    _failure = exhausted
        ? SshFailure(
            stage: failure.stage,
            host: failure.host,
            port: failure.port,
            message:
                '${failure.message}已尝试自动重连 $_reconnectAttempt 次仍未成功，请检查网络后手动重试。',
            cause: failure.cause,
          )
        : failure;
    if (exhausted) _emitNotice('自动重连失败，已停止重试。');
    _record(
      SshConnectionEventKind.failure,
      _failure!.message,
      stage: failure.stage,
      error: failure.cause,
    );
    _reconnectAttempt = 0;
    _setState(SshConnectionState.failed);
  }

  void _cleanupConnection() {
    _health.stop();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _browseSftp = null;
    _browseSftpPending = null;
    final sftpSessions = List<SftpSession>.of(_sftpSessions);
    _sftpSessions.clear();
    for (final session in sftpSessions) {
      unawaited(closeSftpSession(session));
    }
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _stdoutDone = null;
    _stderrDone = null;
    _connection?.close();
    _connection = null;
    _cancellationToken?.cancel();
    _cancellationToken = null;
    _resizeWarned = false;
    _resizePending = true;
  }

  void _record(
    SshConnectionEventKind kind,
    String message, {
    SshConnectionState? state,
    SshFailureStage? stage,
    Object? error,
  }) {
    if (_disposed) return;
    _events.add(kind, message, state: state, stage: stage, error: error);
    _notifyListeners();
  }

  void _setState(SshConnectionState state) {
    if (_state == state) return;
    _state = state;
    _events.add(
      SshConnectionEventKind.state,
      '状态：${state.label}',
      state: state,
    );
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _health.dispose();
    _cleanupConnection();
    unawaited(_outputController.close());
    super.dispose();
  }
}
