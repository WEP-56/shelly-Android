import 'dart:math';

/// Bounded retry with exponential backoff and jitter.
///
/// Shared by everything that reconnects: the agent transport
/// ([AgentRetryPolicy]) and the SSH session's auto-reconnect.
class BackoffPolicy {
  const BackoffPolicy({
    required this.maxRetries,
    required this.baseDelay,
    required this.maxDelay,
  });

  /// Retry attempts after the initial call. The initial call never counts.
  final int maxRetries;
  final Duration baseDelay;
  final Duration maxDelay;

  bool get enabled => maxRetries > 0;

  /// `base * 2^(attempt-1)` with ±20% jitter, capped at [maxDelay]. Jitter keeps
  /// several reconnecting clients from hammering the same rebooting endpoint.
  Duration delayFor(int attempt, {Duration? serverRequested}) {
    if (serverRequested != null) {
      return serverRequested > maxDelay ? maxDelay : serverRequested;
    }
    final exponential = baseDelay * pow(2, attempt - 1).toDouble();
    final capped = exponential > maxDelay ? maxDelay : exponential;
    final jitter = 0.8 + Random().nextDouble() * 0.4;
    return Duration(
      milliseconds: (capped.inMilliseconds * jitter).round().clamp(
        0,
        maxDelay.inMilliseconds,
      ),
    );
  }
}
