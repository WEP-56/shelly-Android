/// Typed failures for the agent runtime.
///
/// Every layer converts infrastructure errors into one of these before they
/// reach the loop or the UI, so a failure always carries a stage and a message
/// that is safe to display. API keys, private keys and passphrases never appear
/// in [AgentFailure.message] or [AgentFailure.detail].
library;

enum AgentFailureStage {
  /// No provider configured, missing endpoint/model, or unreadable API key.
  configuration,

  /// DNS, TCP, TLS or proxy failure before an HTTP status was seen.
  transport,

  /// Provider returned a non-2xx status.
  providerStatus,

  /// Provider stream could not be decoded or ended without a terminal event.
  providerProtocol,

  /// The provider ended the turn with an error stop reason.
  providerResponse,

  /// A tool argument failed schema validation.
  toolArguments,

  /// A tool raised while executing.
  toolExecution,

  /// A per-run limit was reached (steps, duration, context size).
  limit,

  /// The user or the app cancelled the run.
  cancelled,
}

class AgentFailure implements Exception {
  const AgentFailure({
    required this.stage,
    required this.message,
    this.detail,
    this.statusCode,
    this.retryAfter,
    this.cause,
  });

  final AgentFailureStage stage;

  /// Short, user-facing Chinese message.
  final String message;

  /// Optional redacted provider/tool detail shown in an expandable area.
  final String? detail;

  final int? statusCode;

  /// Delay the provider asked for via `retry-after`, when it sent one.
  final Duration? retryAfter;

  final Object? cause;

  bool get isCancelled => stage == AgentFailureStage.cancelled;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// Raised by tool argument validation. The loop converts it into an error tool
/// result so the model can correct itself instead of ending the run.
class AgentToolArgumentException implements Exception {
  const AgentToolArgumentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised by a tool when the request is legitimate but cannot be served.
class AgentToolException implements Exception {
  const AgentToolException(this.message);

  final String message;

  @override
  String toString() => message;
}
