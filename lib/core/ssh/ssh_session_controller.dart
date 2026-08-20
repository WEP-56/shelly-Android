import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app/models.dart';
import 'ssh_connection_factory.dart';
import 'ssh_models.dart';

class SshSessionController extends ChangeNotifier {
  SshSessionController({
    required HostProfile host,
    required SshConnectionFactory factory,
    required HostTrustPrompt promptForHostTrust,
    required bool keepAlive,
  }) : _host = host,
       _factory = factory,
       _promptForHostTrust = promptForHostTrust,
       _keepAlive = keepAlive;

  final HostProfile _host;
  final SshConnectionFactory _factory;
  final HostTrustPrompt _promptForHostTrust;
  final bool _keepAlive;
  final StreamController<String> _outputController =
      StreamController<String>.broadcast(sync: true);

  SshConnectionState _state = SshConnectionState.idle;
  SshFailure? _failure;
  SshCancellationToken? _cancellationToken;
  SshConnectionHandle? _connection;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<void>? _stdoutDone;
  Future<void>? _stderrDone;
  int _terminalWidth = 80;
  int _terminalHeight = 24;
  int _terminalPixelWidth = 0;
  int _terminalPixelHeight = 0;
  int _generation = 0;
  bool _disposed = false;

  SshConnectionState get state => _state;
  SshFailure? get failure => _failure;
  Stream<String> get output => _outputController.stream;
  bool get isConnected => _state == SshConnectionState.connected;

  Future<void> connect() => _startConnection(isRetry: false);

  Future<void> retry() => _startConnection(isRetry: true);

  Future<void> _startConnection({required bool isRetry}) async {
    final generation = ++_generation;
    _cleanupConnection();
    _failure = null;
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
        keepAlive: _keepAlive,
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
      try {
        connection.resizeTerminal(
          _terminalWidth,
          _terminalHeight,
          _terminalPixelWidth,
          _terminalPixelHeight,
        );
      } on Object catch (error) {
        connection.close();
        _connection = null;
        throw SshFailure(
          stage: SshFailureStage.session,
          host: _host.host,
          port: _host.port,
          message: '初始化远程终端尺寸失败。',
          cause: error,
        );
      }
      _listenToOutput(connection, generation);
      _setState(SshConnectionState.connected);
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
        _setState(SshConnectionState.disconnected);
      }
    } on SshFailure catch (failure) {
      if (generation != _generation || _disposed) return;
      if (identical(_cancellationToken, token)) _cancellationToken = null;
      _failure = failure;
      _setState(SshConnectionState.failed);
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
      _failure = SshFailure(
        stage: SshFailureStage.session,
        host: _host.host,
        port: _host.port,
        message: '向远程终端发送输入失败。',
        cause: error,
      );
      ++_generation;
      _cleanupConnection();
      _setState(SshConnectionState.failed);
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
    final connection = _connection;
    if (!isConnected || connection == null) return;
    try {
      connection.resizeTerminal(width, height, pixelWidth, pixelHeight);
    } on Object catch (error) {
      _failSession('调整远程终端尺寸失败。', error);
    }
  }

  Future<void> disconnect() async {
    ++_generation;
    _cleanupConnection();
    _failure = null;
    _setState(SshConnectionState.disconnected);
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
    _setState(SshConnectionState.disconnected);
  }

  void _handleRemoteError(Object error, int generation) {
    if (generation != _generation || _disposed) return;
    _failSession('SSH 会话意外断开，请重试连接。', error);
  }

  void _failSession(String message, Object error) {
    if (_disposed) return;
    _failure = SshFailure(
      stage: SshFailureStage.session,
      host: _host.host,
      port: _host.port,
      message: message,
      cause: error,
    );
    ++_generation;
    _cleanupConnection();
    _setState(SshConnectionState.failed);
  }

  void _cleanupConnection() {
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
  }

  void _setState(SshConnectionState state) {
    if (_state == state) return;
    _state = state;
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _cleanupConnection();
    unawaited(_outputController.close());
    super.dispose();
  }
}
