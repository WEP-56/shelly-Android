import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../app/models.dart';
import '../../features/hosts/data/host_repository.dart';
import '../../features/sftp/sftp_session.dart';
import 'known_host_repository.dart';
import 'ssh_models.dart';

class SshConnectionCancelled implements Exception {
  const SshConnectionCancelled();
}

class SshCancellationToken {
  bool _cancelled = false;
  SSHSocket? _socket;
  SSHClient? _client;

  bool get isCancelled => _cancelled;

  void attachSocket(SSHSocket socket) {
    _socket = socket;
    throwIfCancelled();
  }

  void attachClient(SSHClient client) {
    _client = client;
    throwIfCancelled();
  }

  void throwIfCancelled() {
    if (!_cancelled) return;
    _client?.close();
    _socket?.destroy();
    throw const SshConnectionCancelled();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client?.close();
    _socket?.destroy();
  }
}

class SshConnectionHandle {
  SshConnectionHandle({
    required SSHSocket socket,
    required SSHClient client,
    required SSHSession shell,
  }) : _socket = socket,
       _client = client,
       _shell = shell;

  final SSHSocket _socket;
  final SSHClient _client;
  final SSHSession _shell;
  bool _closed = false;
  final Set<SshCommandHandle> _commands = {};

  Stream<Uint8List> get stdout => _shell.stdout;
  Stream<Uint8List> get stderr => _shell.stderr;
  Future<void> get done => _client.done;

  Future<SftpSession> openSftp({void Function()? onClosed}) async {
    if (_closed) throw StateError('SSH session is closed');
    final client = await _client.sftp();
    if (_closed) {
      await client.close();
      throw StateError('SSH session is closed');
    }
    return SftpSession(client, onClosed: onClosed);
  }

  Future<SshCommandHandle> execute(
    String command, {
    void Function()? onClosed,
  }) async {
    if (_closed) throw StateError('SSH session is closed');
    late SshCommandHandle handle;
    final session = await _client.execute(command);
    if (_closed) {
      session.close();
      throw StateError('SSH session is closed');
    }
    handle = SshCommandHandle(
      session,
      onClosed: () {
        _commands.remove(handle);
        onClosed?.call();
      },
    );
    _commands.add(handle);
    return handle;
  }

  void write(Uint8List bytes) {
    if (_closed) throw StateError('SSH session is closed');
    _shell.write(bytes);
  }

  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    if (_closed) throw StateError('SSH session is closed');
    _shell.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final command in List<SshCommandHandle>.of(_commands)) {
      command.close();
    }
    _commands.clear();
    _shell.close();
    _client.close();
    _socket.destroy();
  }
}

/// An independently cancellable remote command channel.
///
/// Closing this handle only terminates the command channel; the interactive
/// shell owned by [SshConnectionHandle] remains available.
class SshCommandHandle {
  SshCommandHandle(this._session, {void Function()? onClosed})
    : _onClosed = onClosed {
    unawaited(
      _session.done.then(
        (_) => _markClosed(),
        onError: (_, _) => _markClosed(),
      ),
    );
  }

  final SSHSession _session;
  final void Function()? _onClosed;
  bool _closed = false;

  Stream<Uint8List> get stdout => _session.stdout;
  Stream<Uint8List> get stderr => _session.stderr;
  Future<void> get done => _session.done;
  int? get exitCode => _session.exitCode;

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    _onClosed?.call();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _session.close();
    _onClosed?.call();
  }
}

class SshConnectionFactory {
  SshConnectionFactory({
    required HostRepository hosts,
    required KnownHostRepository knownHosts,
  }) : _hosts = hosts,
       _knownHosts = knownHosts;

  static const _socketTimeout = Duration(seconds: 15);
  static const _handshakeTimeout = Duration(seconds: 15);
  static const _authenticationTimeout = Duration(seconds: 20);
  static const _shellTimeout = Duration(seconds: 30);

  final HostRepository _hosts;
  final KnownHostRepository _knownHosts;

  Future<SshConnectionHandle> connect({
    required HostProfile profile,
    required HostTrustPrompt promptForHostTrust,
    required void Function(SshConnectionState state) onStateChanged,
    required SshCancellationToken cancellationToken,
    required bool keepAlive,
    required SshTerminalSize terminalSize,
  }) async {
    SSHSocket? socket;
    SSHClient? client;
    var phase = _ConnectPhase.credential;
    var hostKeyRejected = false;
    HostKeyChallenge? changedHostKey;
    var authenticated = false;

    try {
      final storedCredential = await _hosts.readCredential(profile);
      if (storedCredential == null) {
        throw SshFailure(
          stage: SshFailureStage.credential,
          host: profile.host,
          port: profile.port,
          message: '没有找到该设备的认证资料，请重新编辑设备。',
        );
      }
      final identities = profile.authType == HostAuthType.privateKey
          ? _decodePrivateKey(storedCredential, profile)
          : null;
      cancellationToken.throwIfCancelled();

      phase = _ConnectPhase.socket;
      onStateChanged(SshConnectionState.connecting);
      socket = await SSHSocket.connect(
        profile.host,
        profile.port,
        timeout: _socketTimeout,
      );
      cancellationToken.attachSocket(socket);

      phase = _ConnectPhase.authentication;
      onStateChanged(SshConnectionState.authenticating);
      client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        onPasswordRequest: profile.authType == HostAuthType.password
            ? () => storedCredential
            : null,
        onVerifyHostKey: (algorithm, fingerprintBytes) async {
          phase = _ConnectPhase.hostKey;
          final fingerprint = utf8.decode(fingerprintBytes);
          final known = await _knownHosts.find(
            host: profile.host,
            port: profile.port,
            algorithm: algorithm,
          );
          cancellationToken.throwIfCancelled();
          if (known == null) {
            onStateChanged(SshConnectionState.awaitingHostTrust);
            final challenge = HostKeyChallenge(
              host: profile.host,
              port: profile.port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            );
            final accepted = await promptForHostTrust(challenge);
            cancellationToken.throwIfCancelled();
            if (!accepted) {
              hostKeyRejected = true;
              return false;
            }
            await _knownHosts.trust(
              host: profile.host,
              port: profile.port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            );
            phase = _ConnectPhase.authentication;
            onStateChanged(SshConnectionState.authenticating);
            return true;
          }
          if (known.fingerprint != fingerprint) {
            changedHostKey = HostKeyChallenge(
              host: profile.host,
              port: profile.port,
              algorithm: algorithm,
              fingerprint: fingerprint,
              previousFingerprint: known.fingerprint,
            );
            onStateChanged(SshConnectionState.awaitingHostTrust);
            await promptForHostTrust(changedHostKey!);
            cancellationToken.throwIfCancelled();
            return false;
          }
          await _knownHosts.markSeen(known);
          cancellationToken.throwIfCancelled();
          phase = _ConnectPhase.authentication;
          onStateChanged(SshConnectionState.authenticating);
          return true;
        },
        onAuthenticated: () {
          authenticated = true;
          phase = _ConnectPhase.shell;
        },
        keepAliveInterval: keepAlive ? const Duration(seconds: 15) : null,
        handshakeTimeout: _handshakeTimeout,
        authTimeout: _authenticationTimeout,
      );
      cancellationToken.attachClient(client);

      final shell = await client
          .shell(
            pty: SSHPtyConfig(
              type: 'xterm-256color',
              width: terminalSize.width,
              height: terminalSize.height,
              pixelWidth: terminalSize.pixelWidth,
              pixelHeight: terminalSize.pixelHeight,
            ),
          )
          .timeout(_shellTimeout);
      cancellationToken.throwIfCancelled();
      return SshConnectionHandle(socket: socket, client: client, shell: shell);
    } on SshConnectionCancelled {
      client?.close();
      socket?.destroy();
      rethrow;
    } on SshFailure {
      client?.close();
      socket?.destroy();
      rethrow;
    } on Object catch (error) {
      client?.close();
      socket?.destroy();
      throw _mapFailure(
        error: error,
        profile: profile,
        phase: phase,
        authenticated: authenticated,
        hostKeyRejected: hostKeyRejected,
        changedHostKey: changedHostKey,
      );
    }
  }

  List<SSHKeyPair> _decodePrivateKey(String encoded, HostProfile profile) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const FormatException();
      final credential = Map<String, Object?>.from(decoded);
      final privateKey = credential['privateKey'];
      final passphrase = credential['passphrase'];
      if (privateKey is! String || passphrase is! String) {
        throw const FormatException();
      }
      return SSHKeyPair.fromPem(
        privateKey,
        passphrase.isEmpty ? null : passphrase,
      );
    } on Object catch (error) {
      throw SshFailure(
        stage: SshFailureStage.credential,
        host: profile.host,
        port: profile.port,
        message: '私钥或私钥口令无效，请重新编辑设备。',
        cause: error,
      );
    }
  }

  SshFailure _mapFailure({
    required Object error,
    required HostProfile profile,
    required _ConnectPhase phase,
    required bool authenticated,
    required bool hostKeyRejected,
    required HostKeyChallenge? changedHostKey,
  }) {
    if (changedHostKey != null) {
      return SshFailure(
        stage: SshFailureStage.hostKey,
        host: profile.host,
        port: profile.port,
        message: '主机密钥已变化。连接已阻止，请核对后在设置中删除旧指纹。',
        cause: error,
      );
    }
    if (hostKeyRejected || error is SSHHostkeyError) {
      return SshFailure(
        stage: SshFailureStage.hostKey,
        host: profile.host,
        port: profile.port,
        message: hostKeyRejected ? '你拒绝了该主机的指纹，连接已取消。' : '主机密钥验证失败。',
        cause: error,
      );
    }
    if (error is SocketException) {
      final isDns = error.message.toLowerCase().contains('failed host lookup');
      return SshFailure(
        stage: isDns ? SshFailureStage.dns : SshFailureStage.connect,
        host: profile.host,
        port: profile.port,
        message: isDns ? '无法解析主机地址，请检查地址和网络。' : '无法连接到主机，请检查地址、端口和网络。',
        cause: error,
      );
    }
    if (error is TimeoutException) {
      final stage = authenticated || phase == _ConnectPhase.shell
          ? SshFailureStage.shell
          : phase == _ConnectPhase.authentication
          ? SshFailureStage.authentication
          : SshFailureStage.connect;
      return SshFailure(
        stage: stage,
        host: profile.host,
        port: profile.port,
        message: switch (stage) {
          SshFailureStage.shell => '创建远程 shell 超时。',
          SshFailureStage.authentication => 'SSH 认证超时。',
          _ => 'SSH 连接超时。',
        },
        cause: error,
      );
    }
    if (error is SSHHandshakeError) {
      return SshFailure(
        stage: SshFailureStage.handshake,
        host: profile.host,
        port: profile.port,
        message: 'SSH 握手失败，服务器可能不支持当前算法。',
        cause: error,
      );
    }
    if (error is SSHAuthError || error is SSHKeyDecodeError) {
      return SshFailure(
        stage: SshFailureStage.authentication,
        host: profile.host,
        port: profile.port,
        message: '认证失败，请检查用户名和认证资料。',
        cause: error,
      );
    }
    if (error is SSHChannelOpenError || error is SSHChannelRequestError) {
      return SshFailure(
        stage: SshFailureStage.shell,
        host: profile.host,
        port: profile.port,
        message: 'SSH 已认证，但无法创建远程 shell。',
        cause: error,
      );
    }
    return SshFailure(
      stage: switch (phase) {
        _ConnectPhase.credential => SshFailureStage.credential,
        _ConnectPhase.hostKey => SshFailureStage.hostKey,
        _ConnectPhase.authentication => SshFailureStage.authentication,
        _ConnectPhase.shell => SshFailureStage.shell,
        _ConnectPhase.socket => SshFailureStage.connect,
      },
      host: profile.host,
      port: profile.port,
      message: switch (phase) {
        _ConnectPhase.credential => '无法读取认证资料，请重新编辑设备。',
        _ConnectPhase.hostKey => '无法读取或保存主机指纹，连接已阻止。',
        _ConnectPhase.authentication => 'SSH 认证失败，请检查用户名和认证资料。',
        _ConnectPhase.shell => '无法创建远程 shell。',
        _ConnectPhase.socket => 'SSH 连接失败，请重试。',
      },
      cause: error,
    );
  }
}

enum _ConnectPhase { credential, socket, hostKey, authentication, shell }

class SshTerminalSize {
  const SshTerminalSize({
    required this.width,
    required this.height,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  final int width;
  final int height;
  final int pixelWidth;
  final int pixelHeight;
}
