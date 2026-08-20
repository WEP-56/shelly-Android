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
