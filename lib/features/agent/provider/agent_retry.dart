import '../../../core/retry/backoff_policy.dart';
import '../domain/agent_failure.dart';

/// Bounded retry with exponential backoff.
///
/// Two layers use it:
/// - the HTTP transport retries a request that failed before any bytes streamed;
/// - the loop retries a whole assistant turn whose stream died mid-flight.
class AgentRetryPolicy extends BackoffPolicy {
  const AgentRetryPolicy({
    super.maxRetries = 10,
    super.baseDelay = const Duration(milliseconds: 600),
    super.maxDelay = const Duration(seconds: 30),
  });

  static const disabled = AgentRetryPolicy(maxRetries: 0);
}

/// Classifies whether a failure is worth retrying.
///
/// Deliberate account, auth and quota failures fail fast: retrying them only
/// burns the user's time and, for a 401, can trip provider lockouts.
abstract final class AgentRetryClassifier {
  static final _nonRetryable = RegExp(
    [
      'insufficient_quota',
      'quota exceeded',
      'out of budget',
      'billing',
      'invalid_api_key',
      'invalid api key',
      'authentication',
      'permission',
      'not found',
      'model_not_found',
      'context_length_exceeded',
      'invalid_request',
    ].join('|'),
    caseSensitive: false,
  );

  static final _retryable = RegExp(
    [
      'overloaded',
      r'rate.?limit',
      'too many requests',
      r'service.?unavailable',
      r'server.?error',
      r'internal.?error',
      r'provider.?returned.?error',
      r'network.?error',
      r'connection.?error',
      r'connection.?refused',
      r'connection.?reset',
      r'connection.?closed',
      'socket',
      'handshake',
      'failed host lookup',
      r'timed? out',
      'timeout',
      'terminated',
      'ended without',
      'ended before',
      'stream closed',
    ].join('|'),
    caseSensitive: false,
  );

  static bool isRetryable(AgentFailure failure) {
    switch (failure.stage) {
      case AgentFailureStage.cancelled:
      case AgentFailureStage.configuration:
      case AgentFailureStage.toolArguments:
      case AgentFailureStage.toolExecution:
      case AgentFailureStage.limit:
        return false;
      case AgentFailureStage.transport:
      case AgentFailureStage.providerProtocol:
        return true;
      case AgentFailureStage.providerStatus:
        return isRetryableStatus(failure.statusCode);
      case AgentFailureStage.providerResponse:
        final text = '${failure.message} ${failure.detail ?? ''}';
        if (_nonRetryable.hasMatch(text)) return false;
        return _retryable.hasMatch(text);
    }
  }

  /// Mirrors the retry policy the Anthropic and OpenAI SDKs use.
  static bool isRetryableStatus(int? status) {
    if (status == null) return true;
    return status == 408 || status == 409 || status == 429 || status >= 500;
  }

  /// Parses `retry-after` / `retry-after-ms` response headers.
  static Duration? serverRequestedDelay(Map<String, String> headers) {
    final milliseconds = headers['retry-after-ms'];
    if (milliseconds != null) {
      final value = double.tryParse(milliseconds.trim());
      if (value != null && value >= 0) {
        return Duration(milliseconds: value.round());
      }
    }
    final seconds = headers['retry-after'];
    if (seconds == null) return null;
    final value = double.tryParse(seconds.trim());
    if (value != null && value >= 0) {
      return Duration(milliseconds: (value * 1000).round());
    }
    final date = DateTime.tryParse(seconds.trim());
    if (date == null) return null;
    final delay = date.difference(DateTime.now());
    return delay.isNegative ? Duration.zero : delay;
  }
}
