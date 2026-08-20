import 'dart:async';

import '../domain/agent_event.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_message.dart';
import '../domain/agent_provider_config.dart';
import 'agent_json.dart';
import 'agent_provider.dart';
import 'provider_transport.dart';
import 'sse_decoder.dart';

/// OpenAI Responses protocol adapter.
///
/// Runs with `store: false` and replays only `message` and `function_call`
/// output items. Reasoning items are deliberately not replayed: without
/// `include: ["reasoning.encrypted_content"]` a stateless replay of a reasoning
/// item is rejected, and requesting encrypted reasoning is not portable across
/// the OpenAI-compatible gateways users configure here. Reasoning summaries
/// surface as [AgentStatusKind.reasoning] status only.
class ResponsesAgentProvider implements AgentProvider {
  ResponsesAgentProvider({ProviderTransport? transport})
    : _transport = transport ?? ProviderTransport();

  final ProviderTransport _transport;

  @override
  AgentProviderProtocol get protocol => AgentProviderProtocol.responses;

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
    final slots = <int, _OutputSlot>{};
    var usage = const AgentUsage();
    var stopReason = AgentStopReason.pending;
    String? responseId;
    String? rawStopReason;
    var sawTerminalEvent = false;
    var sawFirstEvent = false;

    AgentAssistantMessage buildMessage(
      AgentStopReason reason, {
      String? errorMessage,
    }) {
      final ordered = slots.keys.toList()..sort();
      final content = <AgentContent>[];
      for (final index in ordered) {
        final slot = slots[index]!;
        final block = slot.content;
        if (block != null) content.add(block);
      }
      return AgentAssistantMessage(
        content: content,
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
          'authorization': 'Bearer ${request.apiKey}',
        },
        body: _buildBody(request),
        timeout: request.config.timeout,
        cancellation: request.cancellation,
      );

      await for (final event in events) {
        final payload = _decode(event);
        final type = payload['type'] as String?;
        if (type == null) continue;
        if (!sawFirstEvent) {
          sawFirstEvent = true;
          sink.add(const ProviderMessageStartEvent());
          sink.add(
            const ProviderStatusEvent(
              AgentStatus(kind: AgentStatusKind.streaming),
            ),
          );
        }

        switch (type) {
          case 'response.created':
            final response = payload['response'];
            if (response is Map) responseId = response['id'] as String?;

          case 'response.output_item.added':
            _createSlot(payload, slots, sink);

          case 'response.reasoning_summary_text.delta':
          case 'response.reasoning_text.delta':
            sink.add(
              const ProviderStatusEvent(
                AgentStatus(kind: AgentStatusKind.reasoning),
              ),
            );

          case 'response.output_text.delta':
          case 'response.refusal.delta':
            final slot = _slot(payload, slots, _SlotKind.text);
            final delta = payload['delta'] as String? ?? '';
            if (slot == null || delta.isEmpty) break;
            slot.text = (slot.text ?? '') + delta;
            sink.add(ProviderTextDeltaEvent(delta));

          case 'response.function_call_arguments.delta':
            final slot = _slot(payload, slots, _SlotKind.toolCall);
            final delta = payload['delta'] as String? ?? '';
            if (slot == null || delta.isEmpty) break;
            slot.arguments.write(delta);
            sink.add(
              ProviderToolCallDeltaEvent(id: slot.toolCallId!, delta: delta),
            );

          case 'response.function_call_arguments.done':
            final slot = _slot(payload, slots, _SlotKind.toolCall);
            final complete = payload['arguments'] as String?;
            if (slot == null || complete == null) break;
            final previous = slot.arguments.toString();
            slot.arguments
              ..clear()
              ..write(complete);
            if (complete.length > previous.length &&
                complete.startsWith(previous)) {
              sink.add(
                ProviderToolCallDeltaEvent(
                  id: slot.toolCallId!,
                  delta: complete.substring(previous.length),
                ),
              );
            }

          case 'response.output_item.done':
            _finishSlot(payload, slots, sink);

          case 'response.completed':
          case 'response.incomplete':
            sawTerminalEvent = true;
            final response = payload['response'];
            if (response is! Map) break;
            final map = Map<String, Object?>.from(response);
            responseId = map['id'] as String? ?? responseId;
            final nextUsage = _usage(map['usage']);
            if (nextUsage != null) {
              usage = nextUsage;
              sink.add(ProviderUsageEvent(usage));
            }
            final status = map['status'] as String?;
            final incomplete = map['incomplete_details'];
            final incompleteReason = incomplete is Map
                ? incomplete['reason'] as String?
                : null;
            rawStopReason = incompleteReason == null
                ? status
                : '$status.$incompleteReason';
            stopReason = _mapStopReason(status, incompleteReason);
            if (stopReason == AgentStopReason.stop &&
                slots.values.any((slot) => slot.kind == _SlotKind.toolCall)) {
              stopReason = AgentStopReason.toolUse;
            }
            sink.add(
              const ProviderStatusEvent(
                AgentStatus(kind: AgentStatusKind.finishing),
              ),
            );

          case 'response.failed':
            sawTerminalEvent = true;
            final response = payload['response'];
            throw AgentFailure(
              stage: AgentFailureStage.providerResponse,
              message: '模型返回失败状态，请重试。',
              detail: response is Map
                  ? AgentJson.describeErrorBody(response['error'].toString())
                  : null,
            );

          case 'error':
            throw AgentFailure(
              stage: AgentFailureStage.providerResponse,
              message: '模型返回错误，请重试。',
              detail: AgentJson.describeErrorBody(event.data),
            );
        }
      }

      request.cancellation.throwIfCancelled();
      if (!sawTerminalEvent) {
        throw const AgentFailure(
          stage: AgentFailureStage.providerProtocol,
          message: '模型响应意外中断，请重试。',
          detail: 'stream ended before a terminal response event',
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

  void _createSlot(
    Map<String, Object?> payload,
    Map<int, _OutputSlot> slots,
    EventSink<ProviderEvent> sink,
  ) {
    final index = (payload['output_index'] as num?)?.toInt();
    final item = payload['item'];
    if (index == null || item is! Map) return;
    if (slots.containsKey(index)) return;
    switch (item['type']) {
      case 'message':
        slots[index] = _OutputSlot(kind: _SlotKind.text, text: '');
      case 'reasoning':
        slots[index] = _OutputSlot(kind: _SlotKind.reasoning);
        sink.add(
          const ProviderStatusEvent(
            AgentStatus(kind: AgentStatusKind.reasoning),
          ),
        );
      case 'function_call':
        final callId =
            item['call_id'] as String? ?? item['id'] as String? ?? '';
        final name = item['name'] as String? ?? '';
        final slot = _OutputSlot(kind: _SlotKind.toolCall, toolCallId: callId)
          ..toolName = name;
        final initial = item['arguments'] as String?;
        if (initial != null) slot.arguments.write(initial);
        slots[index] = slot;
        sink.add(ProviderToolCallStartEvent(id: callId, name: name));
    }
  }

  void _finishSlot(
    Map<String, Object?> payload,
    Map<int, _OutputSlot> slots,
    EventSink<ProviderEvent> sink,
  ) {
    final index = (payload['output_index'] as num?)?.toInt();
    final item = payload['item'];
    if (index == null || item is! Map) return;
    _createSlot(payload, slots, sink);
    final slot = slots[index];
    if (slot == null) return;
    switch (slot.kind) {
      case _SlotKind.text:
        final content = item['content'];
        if (content is List) {
          final buffer = StringBuffer();
          for (final part in content) {
            if (part is! Map) continue;
            final text = part['text'] ?? part['refusal'];
            if (text is String) buffer.write(text);
          }
          if (buffer.isNotEmpty) slot.text = buffer.toString();
        }
        slot.itemId = item['id'] as String?;
      case _SlotKind.toolCall:
        final complete = item['arguments'] as String?;
        if (complete != null) {
          slot.arguments
            ..clear()
            ..write(complete);
        }
        final block = slot.content;
        if (block is AgentToolCallContent) {
          sink.add(ProviderToolCallEndEvent(block));
        }
      case _SlotKind.reasoning:
        break;
    }
  }

  _OutputSlot? _slot(
    Map<String, Object?> payload,
    Map<int, _OutputSlot> slots,
    _SlotKind kind,
  ) {
    final index = (payload['output_index'] as num?)?.toInt();
    if (index == null) return null;
    final slot = slots[index];
    return slot != null && slot.kind == kind ? slot : null;
  }

  Map<String, Object?> _decode(SseEvent event) {
    try {
      return AgentJson.decodeObject(event.data);
    } on FormatException catch (error) {
      throw AgentFailure(
        stage: AgentFailureStage.providerProtocol,
        message: '无法解析模型响应，请重试。',
        detail: 'bad ${event.event ?? 'response'} payload: ${error.message}',
        cause: error,
      );
    }
  }

  Map<String, Object?> _buildBody(ProviderRequest request) {
    return {
      'model': request.config.model,
      'stream': true,
      'store': false,
      'max_output_tokens': request.config.maxOutputTokens,
      'instructions': request.systemPrompt,
      'input': _convertMessages(request.messages),
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.schema.toJsonSchema(),
            },
        ],
    };
  }

  List<Map<String, Object?>> _convertMessages(List<AgentMessage> messages) {
    final input = <Map<String, Object?>>[];
    for (final message in messages) {
      switch (message) {
        case AgentUserMessage(:final text):
          input.add({
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': text},
            ],
          });
        case AgentAssistantMessage():
          for (final block in message.content) {
            switch (block) {
              case AgentTextContent(:final text) when text.trim().isNotEmpty:
                input.add({
                  'type': 'message',
                  'role': 'assistant',
                  'status': 'completed',
                  'content': [
                    {'type': 'output_text', 'text': text, 'annotations': []},
                  ],
                });
              case AgentToolCallContent(:final id, :final name):
                input.add({
                  'type': 'function_call',
                  'call_id': id,
                  'name': name,
                  'arguments': block.rawArguments.trim().isEmpty
                      ? '{}'
                      : block.rawArguments,
                });
              case AgentTextContent():
              case AgentOpaqueContent():
                break;
            }
          }
        case AgentToolResultMessage():
          input.add({
            'type': 'function_call_output',
            'call_id': message.toolCallId,
            'output': message.text,
          });
      }
    }
    return input;
  }

  AgentUsage? _usage(Object? value) {
    if (value is! Map) return null;
    final input = (value['input_tokens'] as num?)?.toInt() ?? 0;
    final output = (value['output_tokens'] as num?)?.toInt() ?? 0;
    final total = (value['total_tokens'] as num?)?.toInt() ?? input + output;
    final details = value['input_tokens_details'];
    final cached = details is Map
        ? (details['cached_tokens'] as num?)?.toInt() ?? 0
        : 0;
    // OpenAI counts cached tokens inside input_tokens; split them out so the UI
    // does not double count.
    return AgentUsage(
      inputTokens: input - cached < 0 ? 0 : input - cached,
      outputTokens: output,
      cacheReadTokens: cached,
      totalTokens: total,
    );
  }

  AgentStopReason _mapStopReason(String? status, String? incompleteReason) {
    return switch (status) {
      'completed' => AgentStopReason.stop,
      'in_progress' || 'queued' => AgentStopReason.stop,
      'incomplete' when incompleteReason == 'max_output_tokens' =>
        AgentStopReason.length,
      _ => AgentStopReason.error,
    };
  }
}

enum _SlotKind { text, toolCall, reasoning }

class _OutputSlot {
  _OutputSlot({required this.kind, this.text, this.toolCallId});

  final _SlotKind kind;
  final StringBuffer arguments = StringBuffer();
  String? text;
  String? toolCallId;
  String? toolName;
  String? itemId;

  AgentContent? get content {
    switch (kind) {
      case _SlotKind.text:
        final value = text;
        return value == null || value.isEmpty ? null : AgentTextContent(value);
      case _SlotKind.toolCall:
        final id = toolCallId;
        if (id == null) return null;
        final raw = arguments.toString();
        return AgentToolCallContent(
          id: id,
          name: toolName ?? '',
          arguments: AgentJson.decodeArguments(raw),
          rawArguments: raw,
        );
      case _SlotKind.reasoning:
        return null;
    }
  }
}
