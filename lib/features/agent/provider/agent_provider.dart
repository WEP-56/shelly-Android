import '../domain/agent_event.dart';
import '../domain/agent_message.dart';
import '../domain/agent_provider_config.dart';
import '../domain/agent_tool.dart';

class ProviderRequest {
  const ProviderRequest({
    required this.config,
    required this.apiKey,
    required this.systemPrompt,
    required this.messages,
    required this.tools,
    required this.cancellation,
  });

  final AgentProviderConfig config;

  /// Resolved at request time from secure storage. Never persisted or logged.
  final String apiKey;

  final String systemPrompt;
  final List<AgentMessage> messages;
  final List<AgentTool> tools;
  final AgentCancellationToken cancellation;
}

/// One wire protocol, normalized onto [ProviderEvent].
///
/// Contract: [stream] must not throw once called. Configuration, transport and
/// protocol failures arrive as a terminal [ProviderErrorEvent] so the loop has a
/// single failure path and always ends with a complete assistant message.
abstract interface class AgentProvider {
  AgentProviderProtocol get protocol;

  Stream<ProviderEvent> stream(ProviderRequest request);
}
