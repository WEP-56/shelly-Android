import 'dart:async';

import '../domain/agent_event.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_message.dart';
import '../domain/agent_provider_config.dart';
import '../domain/agent_tool.dart';
import '../provider/agent_provider.dart';
import '../provider/agent_retry.dart';
import '../tools/agent_tool_set.dart';
import 'tool_output.dart';

/// Per-run ceilings. They exist so a confused model cannot loop forever, hold an
/// SSH session hostage, or grow the context until the provider rejects it.
class AgentLoopLimits {
  const AgentLoopLimits({
    this.maxSteps = 24,
    this.maxDuration = const Duration(minutes: 15),
    this.maxContextChars = 400 * 1024,
    this.maxToolResultBytes = 32 * 1024,
  });

  /// Provider requests per run, including the ones that only carry tool results.
  final int maxSteps;

  final Duration maxDuration;

  /// Rough transcript size guard, measured in characters of text actually sent.
  final int maxContextChars;

  final int maxToolResultBytes;
}

/// One supervised agent run: stream an assistant turn, execute its tool calls,
/// feed the results back, repeat until the model stops asking for tools.
///
/// Failure handling follows the two-layer shape used by production coding
/// agents: the transport retries a request that died before any bytes arrived,
/// and this loop retries a whole assistant turn whose stream broke mid-flight
/// (up to [AgentRetryPolicy.maxRetries] attempts with exponential backoff).
/// Tool problems never kill the loop — they come back as error tool results the
/// model can react to.
class AgentLoop {
  AgentLoop({
    required AgentProvider provider,
    required AgentProviderConfig config,
    required String apiKey,
    required String systemPrompt,
    required AgentToolSet toolSet,
    AgentLoopLimits limits = const AgentLoopLimits(),
    AgentRetryPolicy retryPolicy = const AgentRetryPolicy(),
  }) : _provider = provider,
       _config = config,
       _apiKey = apiKey,
       _systemPrompt = systemPrompt,
       _toolSet = toolSet,
       _limits = limits,
       _retryPolicy = retryPolicy;

  final AgentProvider _provider;
  final AgentProviderConfig _config;
  final String _apiKey;
  final String _systemPrompt;
  final AgentToolSet _toolSet;
  final AgentLoopLimits _limits;
  final AgentRetryPolicy _retryPolicy;

  final AgentCancellationToken cancellation = AgentCancellationToken();

  AgentAssistantMessage? _streaming;
  bool _started = false;

  /// The assistant message currently being streamed, or null between turns.
  AgentAssistantMessage? get streamingMessage => _streaming;

  bool get isCancelled => cancellation.isCancelled;

  /// Cancels the provider stream and every in-flight tool.
  void cancel() => cancellation.cancel();

  /// Runs the loop over [history], which must already contain the new user
  /// message. The stream always ends with exactly one of [AgentRunCompleted],
  /// [AgentRunCancelled] or [AgentRunFailed].
  Stream<AgentRuntimeEvent> run(List<AgentMessage> history) async* {
    if (_started) {
      throw StateError('AgentLoop 只能运行一次。');
    }
    _started = true;
    final messages = [...history];
    final deadline = DateTime.now().add(_limits.maxDuration);
    var usage = const AgentUsage();
    var step = 0;

    yield const AgentRunStarted();

    while (true) {
      if (cancellation.isCancelled) {
        _streaming = null;
        yield const AgentRunCancelled();
        return;
      }
      if (step >= _limits.maxSteps) {
        yield AgentRunFailed(
          AgentFailure(
            stage: AgentFailureStage.limit,
            message: '本轮已达到 ${_limits.maxSteps} 次模型调用上限，已停止。',
            detail: '如果任务尚未完成，请补充信息后重新提问。',
          ),
        );
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        yield AgentRunFailed(
          AgentFailure(
            stage: AgentFailureStage.limit,
            message: '本轮已超过 ${_limits.maxDuration.inMinutes} 分钟上限，已停止。',
          ),
        );
        return;
      }
      final contextChars = _contextChars(messages);
      if (contextChars > _limits.maxContextChars) {
        yield AgentRunFailed(
          AgentFailure(
            stage: AgentFailureStage.limit,
            message: '会话上下文过长，已停止。请新建会话后继续。',
            detail: '当前约 $contextChars 字符，上限 ${_limits.maxContextChars} 字符。',
          ),
        );
        return;
      }

      step++;
      yield AgentTurnStarted(step);

      final turn = _TurnHolder();
      yield* _streamTurnWithRetry(messages, turn);

      final assistant = turn.resolveMessage();
      messages.add(assistant);
      _streaming = null;
      yield AgentMessageAppended(assistant);
      if (!assistant.usage.isEmpty) {
        usage = usage + assistant.usage;
        yield AgentUsageReported(usage);
      }

      if (turn.cancelled || cancellation.isCancelled) {
        yield const AgentRunCancelled();
        return;
      }
      final failure = turn.failure;
      if (failure != null) {
        yield AgentRunFailed(failure);
        return;
      }

      final calls = assistant.toolCalls.toList(growable: false);
      if (calls.isEmpty) {
        yield const AgentStatusChanged(
          AgentStatus(kind: AgentStatusKind.finishing),
        );
        yield AgentRunCompleted(usage: usage, steps: step);
        return;
      }

      final truncated = assistant.stopReason == AgentStopReason.length;
      for (final call in calls) {
        if (truncated) {
          final result = _errorResult(
            call,
            '模型输出在参数写完之前被长度上限截断，这次调用没有执行。请缩短输出或拆分任务后重试。',
          );
          messages.add(result);
          yield AgentToolFinished(result);
          continue;
        }
        if (cancellation.isCancelled) {
          final result = _errorResult(call, '用户已停止本轮运行，这次调用没有执行。');
          messages.add(result);
          yield AgentToolFinished(result);
          continue;
        }
        yield AgentToolStarted(
          toolCallId: call.id,
          toolName: call.name,
          arguments: call.arguments,
        );
        final result = await _executeCall(call);
        messages.add(result);
        yield AgentToolFinished(result);
      }
    }
  }

  /// Streams one assistant turn, retrying the whole turn while the failure is
  /// retryable. Partial text from a failed attempt is discarded rather than
  /// stitched onto the retry.
  Stream<AgentRuntimeEvent> _streamTurnWithRetry(
    List<AgentMessage> messages,
    _TurnHolder holder,
  ) async* {
    var attempt = 0;
    while (true) {
      holder.reset();
      yield* _streamOnce(messages, holder);
      final failure = holder.failure;
      if (failure == null || holder.cancelled || cancellation.isCancelled) {
        return;
      }
      if (!AgentRetryClassifier.isRetryable(failure) ||
          attempt >= _retryPolicy.maxRetries) {
        return;
      }
      attempt++;
      final delay = _retryPolicy.delayFor(
        attempt,
        serverRequested: failure.retryAfter,
      );
      yield AgentStatusChanged(
        AgentStatus(
          kind: AgentStatusKind.retrying,
          summary:
              '${failure.message} 将在 ${_describeDelay(delay)} 后重试'
              '（第 $attempt/${_retryPolicy.maxRetries} 次）。',
          attempt: attempt,
        ),
      );
      await _sleep(delay);
      if (cancellation.isCancelled) return;
    }
  }

  Stream<AgentRuntimeEvent> _streamOnce(
    List<AgentMessage> messages,
    _TurnHolder holder,
  ) async* {
    _streaming = AgentAssistantMessage(
      content: const [],
      stopReason: AgentStopReason.pending,
    );
    yield const AgentStatusChanged(
      AgentStatus(kind: AgentStatusKind.connecting),
    );
    final request = ProviderRequest(
      config: _config,
      apiKey: _apiKey,
      systemPrompt: _systemPrompt,
      messages: List.unmodifiable(messages),
      tools: _toolSet.tools,
      cancellation: cancellation,
    );
    await for (final event in _provider.stream(request)) {
      switch (event) {
        case ProviderMessageStartEvent():
          yield const AgentStatusChanged(
            AgentStatus(kind: AgentStatusKind.streaming),
          );
        case ProviderTextDeltaEvent(:final delta):
          _streaming = _withText(_streaming, delta);
          yield AgentTextDelta(delta);
          yield AgentMessageUpdated(_streaming!);
        case ProviderStatusEvent(:final status):
          yield AgentStatusChanged(status);
        case ProviderToolCallStartEvent(:final id, :final name):
          _streaming = _withToolCall(
            _streaming,
            AgentToolCallContent(
              id: id,
              name: name,
              arguments: const {},
              rawArguments: '',
            ),
          );
          yield AgentMessageUpdated(_streaming!);
        case ProviderToolCallDeltaEvent(:final id, :final delta):
          _streaming = _withToolCallDelta(_streaming, id, delta);
          yield AgentToolCallDelta(id: id, delta: delta);
          yield AgentMessageUpdated(_streaming!);
        case ProviderToolCallEndEvent(:final toolCall):
          _streaming = _withToolCall(_streaming, toolCall);
          yield AgentMessageUpdated(_streaming!);
        case ProviderUsageEvent(:final usage):
          holder.usage = usage;
        case ProviderCompletedEvent(:final message):
          holder.message = message;
        case ProviderCancelledEvent(:final message):
          holder.message = message;
          holder.cancelled = true;
        case ProviderErrorEvent(:final failure, :final message):
          holder.message = message;
          holder.failure = failure;
          holder.cancelled = failure.isCancelled;
      }
    }
    if (holder.message == null && holder.failure == null) {
      holder.failure = const AgentFailure(
        stage: AgentFailureStage.providerProtocol,
        message: '模型响应在给出结果前中断。',
      );
    }
  }

  Future<AgentToolResultMessage> _executeCall(AgentToolCallContent call) async {
    final tool = _toolSet.find(call.name);
    if (tool == null) {
      return _errorResult(
        call,
        '不存在名为 "${call.name}" 的工具。可用工具：'
        '${_toolSet.tools.map((item) => item.name).join('、')}。',
      );
    }
    if (call.arguments.isEmpty &&
        call.rawArguments.trim().isNotEmpty &&
        tool.schema.fields.isNotEmpty) {
      return _errorResult(call, '参数不是合法 JSON，无法解析，工具没有执行。请重新发送完整的 JSON 参数。');
    }
    try {
      final arguments = tool.schema.validate(call.arguments);
      final result = await tool.execute(call.id, arguments, cancellation);
      final bounded = ToolOutput.limit(
        result.text,
        byteLimit: _limits.maxToolResultBytes,
        keepTail: true,
      );
      return AgentToolResultMessage(
        toolCallId: call.id,
        toolName: call.name,
        text: bounded.annotated,
        isError: result.isError,
        details: result.details,
      );
    } on AgentToolArgumentException catch (error) {
      return _errorResult(call, '参数不符合工具定义：${error.message}');
    } on AgentToolException catch (error) {
      return _errorResult(call, error.message);
    } on AgentFailure catch (failure) {
      if (failure.isCancelled) {
        return _errorResult(call, '用户停止了本轮运行，工具执行已中断。');
      }
      return _errorResult(call, '工具执行失败：${failure.message}');
    } on Exception catch (error) {
      return _errorResult(call, '工具执行失败：$error');
    }
  }

  AgentToolResultMessage _errorResult(
    AgentToolCallContent call,
    String message,
  ) {
    return AgentToolResultMessage(
      toolCallId: call.id,
      toolName: call.name,
      text: message,
      isError: true,
    );
  }

  Future<void> _sleep(Duration duration) {
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    cancellation.addListener(() {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  static String _describeDelay(Duration delay) {
    if (delay.inSeconds >= 1) return '${delay.inSeconds} 秒';
    return '${delay.inMilliseconds} 毫秒';
  }

  static int _contextChars(List<AgentMessage> messages) {
    var total = 0;
    for (final message in messages) {
      switch (message) {
        case AgentUserMessage(:final text):
          total += text.length;
        case AgentAssistantMessage(:final content):
          for (final block in content) {
            switch (block) {
              case AgentTextContent(:final text):
                total += text.length;
              case AgentToolCallContent(:final rawArguments, :final name):
                total += rawArguments.length + name.length;
              case AgentOpaqueContent():
                break;
            }
          }
        case AgentToolResultMessage(:final text):
          total += text.length;
      }
    }
    return total;
  }

  static AgentAssistantMessage _withText(
    AgentAssistantMessage? message,
    String delta,
  ) {
    final base =
        message ??
        AgentAssistantMessage(
          content: const [],
          stopReason: AgentStopReason.pending,
        );
    final content = [...base.content];
    final last = content.isEmpty ? null : content.last;
    if (last is AgentTextContent) {
      content[content.length - 1] = last.append(delta);
    } else {
      content.add(AgentTextContent(delta));
    }
    return base.copyWith(content: content);
  }

  static AgentAssistantMessage _withToolCall(
    AgentAssistantMessage? message,
    AgentToolCallContent call,
  ) {
    final base =
        message ??
        AgentAssistantMessage(
          content: const [],
          stopReason: AgentStopReason.pending,
        );
    final content = [...base.content];
    final index = content.indexWhere(
      (block) => block is AgentToolCallContent && block.id == call.id,
    );
    if (index >= 0) {
      content[index] = call;
    } else {
      content.add(call);
    }
    return base.copyWith(content: content);
  }

  static AgentAssistantMessage _withToolCallDelta(
    AgentAssistantMessage? message,
    String id,
    String delta,
  ) {
    final base =
        message ??
        AgentAssistantMessage(
          content: const [],
          stopReason: AgentStopReason.pending,
        );
    final content = [...base.content];
    final index = content.indexWhere(
      (block) => block is AgentToolCallContent && block.id == id,
    );
    if (index < 0) return base;
    final existing = content[index] as AgentToolCallContent;
    content[index] = existing.copyWith(
      rawArguments: '${existing.rawArguments}$delta',
    );
    return base.copyWith(content: content);
  }
}

/// Mutable result of one assistant-turn attempt.
class _TurnHolder {
  AgentAssistantMessage? message;
  AgentFailure? failure;
  AgentUsage? usage;
  bool cancelled = false;

  void reset() {
    message = null;
    failure = null;
    usage = null;
    cancelled = false;
  }

  /// The message appended to the transcript. Always non-null: a turn that never
  /// produced one still becomes a failed assistant message so the transcript and
  /// the tool-call pairing stay valid.
  AgentAssistantMessage resolveMessage() {
    final existing = message;
    final reported = usage;
    if (existing != null) {
      if (existing.usage.isEmpty && reported != null) {
        return existing.copyWith(usage: reported);
      }
      return existing;
    }
    return AgentAssistantMessage(
      content: const [],
      stopReason: cancelled ? AgentStopReason.aborted : AgentStopReason.error,
      usage: reported ?? const AgentUsage(),
      errorMessage: failure?.message,
    );
  }
}
