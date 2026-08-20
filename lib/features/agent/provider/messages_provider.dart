import 'dart:async';

import '../domain/agent_event.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_message.dart';
import '../domain/agent_provider_config.dart';
import 'agent_json.dart';
import 'agent_provider.dart';
import 'provider_transport.dart';
import 'sse_decoder.dart';

/// Anthropic Messages protocol adapter.
///
/// Thinking blocks are never requested. If an endpoint returns one anyway it is
/// reported as a [AgentStatusKind.reasoning] status and dropped from the
/// transcript, so provider-private reasoning is neither displayed nor replayed.
class MessagesAgentProvider implements AgentProvider {
  MessagesAgentProvider({ProviderTransport? transport})
    : _transport = transport ?? ProviderTransport();

  static const _apiVersion = '2023-06-01';
  static const _handledEvents = {
    'message_start',
    'message_delta',
    'message_stop',
    'content_block_start',
    'content_block_delta',
    'content_block_stop',
  };

  final ProviderTransport _transport;

  @override
  AgentProviderProtocol get protocol => AgentProviderProtocol.messages;

  @override
  Stream<ProviderEvent> stream(ProviderRequest request) {
    final controller = StreamController<ProviderEvent>();
    controller.onListen = () {
      unawaited(_run(request, controller).whenComplete(controller.close));
    };
    return controller.stream;
  }

  Future<void> _run(
    ProviderRequest request,
    EventSink<ProviderEvent> sink,
  ) async {
    final blocks = <int, AgentContent>{};
    final toolBuffers = <int, StringBuffer>{};
    var usage = const AgentUsage();
    var stopReason = AgentStopReason.pending;
    String? responseId;
    String? rawStopReason;
    var sawMessageStart = false;
    var sawMessageStop = false;

    AgentAssistantMessage buildMessage(
      AgentStopReason reason, {
      String? errorMessage,
    }) {
      final ordered = blocks.keys.toList()..sort();
      return AgentAssistantMessage(
        content: [for (final index in ordered) blocks[index]!],
        stopReason: reason,
        usage: usage,
        errorMessage: errorMessage,
        responseId: responseId,
      );
    }

    try {
      sink.add(
        const ProviderStatusEvent(
          AgentStatus(kind: AgentStatusKind.connecting),
        ),
      );
      final events = _transport.stream(
        url: request.config.requestUri,
        headers: {
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          'anthropic-version': _apiVersion,
          'x-api-key': request.apiKey,
        },
        body: _buildBody(request),
        timeout: request.config.timeout,
        cancellation: request.cancellation,
      );

      await for (final event in events) {
        if (event.event == 'error') {
          throw AgentFailure(
            stage: AgentFailureStage.providerResponse,
            message: '模型返回错误，请重试。',
            detail: AgentJson.describeErrorBody(event.data),
          );
        }
        if (!_handledEvents.contains(event.event)) continue;
        final payload = _decode(event);

        switch (payload['type']) {
          case 'message_start':
            sawMessageStart = true;
            sink.add(const ProviderMessageStartEvent());
            sink.add(
              const ProviderStatusEvent(
                AgentStatus(kind: AgentStatusKind.streaming),
              ),
            );
            final message = payload['message'];
            if (message is Map) {
              responseId = message['id'] as String?;
              usage = _usage(message['usage'], usage);
              if (!usage.isEmpty) sink.add(ProviderUsageEvent(usage));
            }

          case 'content_block_start':
            final index = (payload['index'] as num?)?.toInt();
            final block = payload['content_block'];
            if (index == null || block is! Map) break;
            switch (block['type']) {
              case 'text':
                blocks[index] = AgentTextContent(
                  block['text'] as String? ?? '',
                );
              case 'thinking':
              case 'redacted_thinking':
                sink.add(
                  const ProviderStatusEvent(
                    AgentStatus(kind: AgentStatusKind.reasoning),
                  ),
                );
              case 'tool_use':
                final id = block['id'] as String? ?? '';
                final name = block['name'] as String? ?? '';
                blocks[index] = AgentToolCallContent(
                  id: id,
                  name: name,
                  arguments: const {},
                  rawArguments: '',
                );
                toolBuffers[index] = StringBuffer();
                sink.add(ProviderToolCallStartEvent(id: id, name: name));
            }

          case 'content_block_delta':
            final index = (payload['index'] as num?)?.toInt();
            final delta = payload['delta'];
            if (index == null || delta is! Map) break;
            switch (delta['type']) {
              case 'text_delta':
                final text = delta['text'] as String? ?? '';
                final current = blocks[index];
                if (current is! AgentTextContent || text.isEmpty) break;
                blocks[index] = current.append(text);
                sink.add(ProviderTextDeltaEvent(text));
              case 'thinking_delta':
              case 'signature_delta':
                break;
              case 'input_json_delta':
                final json = delta['partial_json'] as String? ?? '';
                final current = blocks[index];
                final buffer = toolBuffers[index];
                if (current is! AgentToolCallContent ||
                    buffer == null ||
                    json.isEmpty) {
                  break;
                }
                buffer.write(json);
                final raw = buffer.toString();
                blocks[index] = current.copyWith(
                  rawArguments: raw,
                  arguments: AgentJson.decodePartialArguments(raw),
                );
                sink.add(
                  ProviderToolCallDeltaEvent(id: current.id, delta: json),
                );
            }

          case 'content_block_stop':
            final index = (payload['index'] as num?)?.toInt();
            if (index == null) break;
            final current = blocks[index];
            if (current is! AgentToolCallContent) break;
            final raw = toolBuffers.remove(index)?.toString() ?? '';
            final finalized = current.copyWith(
              rawArguments: raw,
              arguments: AgentJson.decodeArguments(raw),
            );
            blocks[index] = finalized;
            sink.add(ProviderToolCallEndEvent(finalized));

          case 'message_delta':
            final delta = payload['delta'];
            if (delta is Map) {
              final reason = delta['stop_reason'];
              if (reason is String) {
                rawStopReason = reason;
                stopReason = _mapStopReason(reason);
              }
            }
            final nextUsage = _usage(payload['usage'], usage);
            if (nextUsage.totalTokens != usage.totalTokens ||
                nextUsage.outputTokens != usage.outputTokens) {
              usage = nextUsage;
              sink.add(ProviderUsageEvent(usage));
            }

          case 'message_stop':
            sawMessageStop = true;
            sink.add(
              const ProviderStatusEvent(
                AgentStatus(kind: AgentStatusKind.finishing),
              ),
            );
        }
      }

      request.cancellation.throwIfCancelled();
      if (sawMessageStart && !sawMessageStop) {
        throw const AgentFailure(
          stage: AgentFailureStage.providerProtocol,
          message: '模型响应意外中断，请重试。',
          detail: 'stream ended before message_stop',
        );
      }
      if (stopReason == AgentStopReason.pending) {
        throw const AgentFailure(
          stage: AgentFailureStage.providerProtocol,
          message: '模型没有返回结束原因，请重试。',
          detail: 'stream ended without a stop reason',
        );
      }
      if (stopReason == AgentStopReason.error) {
        throw AgentFailure(
          stage: AgentFailureStage.providerResponse,
          message: '模型提前结束了本轮回答。',
          detail: rawStopReason,
        );
      }
      sink.add(ProviderCompletedEvent(buildMessage(stopReason)));
    } on AgentFailure catch (failure) {
      if (failure.isCancelled) {
        sink.add(ProviderCancelledEvent(buildMessage(AgentStopReason.aborted)));
        return;
      }
      sink.add(
        ProviderErrorEvent(
          failure: failure,
          message: buildMessage(
            AgentStopReason.error,
            errorMessage: failure.message,
          ),
        ),
      );
    } on Object catch (error) {
      sink.add(
        ProviderErrorEvent(
          failure: AgentFailure(
            stage: AgentFailureStage.providerProtocol,
            message: '无法解析模型响应，请重试。',
            detail: error.toString(),
            cause: error,
          ),
          message: buildMessage(
            AgentStopReason.error,
            errorMessage: '无法解析模型响应。',
          ),
        ),
      );
    }
  }

  Map<String, Object?> _decode(SseEvent event) {
    try {
      return AgentJson.decodeObject(event.data);
    } on FormatException catch (error) {
      throw AgentFailure(
        stage: AgentFailureStage.providerProtocol,
        message: '无法解析模型响应，请重试。',
        detail: 'bad ${event.event} payload: ${error.message}',
        cause: error,
      );
    }
  }

  Map<String, Object?> _buildBody(ProviderRequest request) {
    return {
      'model': request.config.model,
      'max_tokens': request.config.maxOutputTokens,
      'stream': true,
      'system': request.systemPrompt,
      'messages': _convertMessages(request.messages),
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.schema.toJsonSchema(),
            },
        ],
    };
  }

  /// Anthropic requires every `tool_result` for one assistant turn to arrive in a
  /// single following user message, so consecutive tool results are merged.
  List<Map<String, Object?>> _convertMessages(List<AgentMessage> messages) {
    final converted = <Map<String, Object?>>[];
    final pendingToolResults = <Map<String, Object?>>[];

    void flushToolResults() {
      if (pendingToolResults.isEmpty) return;
      converted.add({
        'role': 'user',
        'content': List<Map<String, Object?>>.of(pendingToolResults),
      });
      pendingToolResults.clear();
    }

    for (final message in messages) {
      switch (message) {
        case AgentUserMessage(:final text):
          flushToolResults();
          converted.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text},
            ],
          });
        case AgentAssistantMessage():
          flushToolResults();
          final content = <Map<String, Object?>>[];
          for (final block in message.content) {
            switch (block) {
              case AgentTextContent(:final text) when text.trim().isNotEmpty:
                content.add({'type': 'text', 'text': text});
              case AgentToolCallContent(:final id, :final name):
                content.add({
                  'type': 'tool_use',
                  'id': id,
                  'name': name,
                  'input': block.arguments,
                });
              case AgentTextContent():
              case AgentOpaqueContent():
                break;
            }
          }
          if (content.isEmpty) break;
          converted.add({'role': 'assistant', 'content': content});
        case AgentToolResultMessage():
          pendingToolResults.add({
            'type': 'tool_result',
            'tool_use_id': message.toolCallId,
            'content': [
              {'type': 'text', 'text': message.text},
            ],
            if (message.isError) 'is_error': true,
          });
      }
    }
    flushToolResults();
    return converted;
  }

  AgentUsage _usage(Object? value, AgentUsage previous) {
    if (value is! Map) return previous;
    final input = (value['input_tokens'] as num?)?.toInt();
    final output = (value['output_tokens'] as num?)?.toInt();
    final cacheRead = (value['cache_read_input_tokens'] as num?)?.toInt();
    final cacheWrite = (value['cache_creation_input_tokens'] as num?)?.toInt();
    final resolved = AgentUsage(
      inputTokens: input ?? previous.inputTokens,
      outputTokens: output ?? previous.outputTokens,
      cacheReadTokens: cacheRead ?? previous.cacheReadTokens,
      cacheWriteTokens: cacheWrite ?? previous.cacheWriteTokens,
    );
    // Anthropic does not report a total; derive it from the components.
    return AgentUsage(
      inputTokens: resolved.inputTokens,
      outputTokens: resolved.outputTokens,
      cacheReadTokens: resolved.cacheReadTokens,
      cacheWriteTokens: resolved.cacheWriteTokens,
      totalTokens:
          resolved.inputTokens +
          resolved.outputTokens +
          resolved.cacheReadTokens +
          resolved.cacheWriteTokens,
    );
  }

  AgentStopReason _mapStopReason(String reason) => switch (reason) {
    'end_turn' || 'stop_sequence' => AgentStopReason.stop,
    'tool_use' || 'pause_turn' => AgentStopReason.toolUse,
    'max_tokens' => AgentStopReason.length,
    _ => AgentStopReason.error,
  };
}
