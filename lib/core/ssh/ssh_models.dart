enum SshConnectionState {
  idle,
  connecting,
  awaitingHostTrust,
  authenticating,
  connected,
  reconnecting,
  disconnected,
  failed,
}

extension SshConnectionStateLabel on SshConnectionState {
  /// Short label used by the connection log and diagnostics.
  String get label => switch (this) {
    SshConnectionState.idle => '未连接',
    SshConnectionState.connecting => '正在连接',
    SshConnectionState.awaitingHostTrust => '等待确认主机指纹',
    SshConnectionState.authenticating => '正在认证',
    SshConnectionState.connected => '已连接',
    SshConnectionState.reconnecting => '正在重连',
    SshConnectionState.disconnected => '已断开',
    SshConnectionState.failed => '连接失败',
  };
}

enum SshFailureStage {
  credential,
  dns,
  connect,
  handshake,
  hostKey,
  authentication,
  shell,
  session,
}

extension SshFailureStageLabel on SshFailureStage {
  /// Short label used by the connection log and diagnostics.
  String get label => switch (this) {
    SshFailureStage.credential => '认证资料',
    SshFailureStage.dns => '域名解析',
    SshFailureStage.connect => '建立连接',
    SshFailureStage.handshake => '协议握手',
    SshFailureStage.hostKey => '主机指纹',
    SshFailureStage.authentication => '身份认证',
    SshFailureStage.shell => '创建 shell',
    SshFailureStage.session => '会话链路',
  };
}

class SshFailure implements Exception {
  const SshFailure({
    required this.stage,
    required this.host,
    required this.port,
    required this.message,
    this.cause,
  });

  final SshFailureStage stage;
  final String host;
  final int port;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class HostKeyChallenge {
  const HostKeyChallenge({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    this.previousFingerprint,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final String? previousFingerprint;

  bool get isChanged => previousFingerprint != null;
}

typedef HostTrustPrompt = Future<bool> Function(HostKeyChallenge challenge);

class KnownHostRecord {
  const KnownHostRecord({
    required this.host,
    required this.port,
    required this.algorithm,
    required this.fingerprint,
    required this.publicKey,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String host;
  final int port;
  final String algorithm;
  final String fingerprint;
  final String publicKey;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
}
