import 'agent_failure.dart';
import 'agent_message.dart';

/// Provider-sanctioned status summaries. Chain-of-thought text is never carried
/// here verbatim: [AgentStatusKind.reasoning] only reports that the model is
/// reasoning, with an optional short provider-supplied summary.
enum AgentStatusKind { connecting, streaming, reasoning, retrying, finishing }

class AgentStatus {
  const AgentStatus({required this.kind, this.summary, this.attempt});

  final AgentStatusKind kind;
  final String? summary;
  final int? attempt;
}

/// Normalized events emitted by every [AgentProvider] adapter regardless of the
/// wire protocol.
///
/// Contract: adapters must not throw after the stream is returned. Request,
/// transport and protocol failures are encoded as [ProviderErrorEvent] followed
/// by stream closure.
sealed class ProviderEvent {
  const ProviderEvent();
}

class ProviderMessageStartEvent extends ProviderEvent {
  const ProviderMessageStartEvent();
}

class ProviderTextDeltaEvent extends ProviderEvent {
  const ProviderTextDeltaEvent(this.delta);

  final String delta;
}

class ProviderStatusEvent extends ProviderEvent {
  const ProviderStatusEvent(this.status);

  final AgentStatus status;
}

class ProviderToolCallStartEvent extends ProviderEvent {
  const ProviderToolCallStartEvent({required this.id, required this.name});

  final String id;
  final String name;
}

class ProviderToolCallDeltaEvent extends ProviderEvent {
  const ProviderToolCallDeltaEvent({required this.id, required this.delta});

  final String id;
  final String delta;
}

class ProviderToolCallEndEvent extends ProviderEvent {
  const ProviderToolCallEndEvent(this.toolCall);

  final AgentToolCallContent toolCall;
}

class ProviderUsageEvent extends ProviderEvent {
  const ProviderUsageEvent(this.usage);

  final AgentUsage usage;
}

/// Terminal success event. [message] is the complete assistant message.
class ProviderCompletedEvent extends ProviderEvent {
  const ProviderCompletedEvent(this.message);

  final AgentAssistantMessage message;
}

/// Terminal cancellation event.
class ProviderCancelledEvent extends ProviderEvent {
  const ProviderCancelledEvent(this.message);

  final AgentAssistantMessage message;
}

/// Terminal failure event. [message] holds whatever partial content arrived.
class ProviderErrorEvent extends ProviderEvent {
  const ProviderErrorEvent({required this.failure, required this.message});

  final AgentFailure failure;
  final AgentAssistantMessage message;
}

/// Runtime events emitted by [AgentLoop]. A superset of [ProviderEvent] that
/// also covers tool execution and the command-approval boundary.
sealed class AgentRuntimeEvent {
  const AgentRuntimeEvent();
}

class AgentRunStarted extends AgentRuntimeEvent {
  const AgentRunStarted();
}

class AgentTurnStarted extends AgentRuntimeEvent {
  const AgentTurnStarted(this.step);

  /// 1-based provider request index within the run.
  final int step;
}

class AgentMessageAppended extends AgentRuntimeEvent {
  const AgentMessageAppended(this.message);

  final AgentMessage message;
}

/// The streaming assistant message changed. The UI re-reads
/// [AgentLoop.streamingMessage] instead of applying the delta itself.
class AgentMessageUpdated extends AgentRuntimeEvent {
  const AgentMessageUpdated(this.message);

  final AgentAssistantMessage message;
}

class AgentTextDelta extends AgentRuntimeEvent {
  const AgentTextDelta(this.delta);

  final String delta;
}

class AgentStatusChanged extends AgentRuntimeEvent {
  const AgentStatusChanged(this.status);

  final AgentStatus status;
}

class AgentToolCallDelta extends AgentRuntimeEvent {
  const AgentToolCallDelta({required this.id, required this.delta});

  final String id;
  final String delta;
}

class AgentToolStarted extends AgentRuntimeEvent {
  const AgentToolStarted({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
  });

  final String toolCallId;
  final String toolName;
  final Map<String, Object?> arguments;
}

class AgentToolFinished extends AgentRuntimeEvent {
  const AgentToolFinished(this.result);

  final AgentToolResultMessage result;
}

class AgentUsageReported extends AgentRuntimeEvent {
  const AgentUsageReported(this.total);

  final AgentUsage total;
}

class AgentRunCompleted extends AgentRuntimeEvent {
  const AgentRunCompleted({required this.usage, required this.steps});

  final AgentUsage usage;
  final int steps;
}

class AgentRunCancelled extends AgentRuntimeEvent {
  const AgentRunCancelled();
}

class AgentRunFailed extends AgentRuntimeEvent {
  const AgentRunFailed(this.failure);

  final AgentFailure failure;
}
