/// Transcript model shared by the provider adapters, the tool loop and the UI.
///
/// Provider-private reasoning never reaches this layer as displayable content.
/// Adapters map reasoning/thinking output to [AgentStatusKind.reasoning] status
/// events instead, so a transcript can be rendered without leaking chain of
/// thought.
library;

enum AgentStopReason { pending, stop, toolUse, length, error, aborted }

sealed class AgentContent {
  const AgentContent();

  Map<String, Object?> toJson();

  static AgentContent? fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      'text' => AgentTextContent(json['text'] as String? ?? ''),
      'toolCall' => AgentToolCallContent(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        arguments: _asStringMap(json['arguments']),
        rawArguments: json['rawArguments'] as String? ?? '',
      ),
      'opaque' => AgentOpaqueContent(
        kind: json['kind'] as String? ?? '',
        payload: _asStringMap(json['payload']),
      ),
      _ => null,
    };
  }
}

Map<String, Object?> _asStringMap(Object? value) {
  if (value is! Map) return const {};
  return Map<String, Object?>.from(value);
}

class AgentTextContent extends AgentContent {
  const AgentTextContent(this.text);

  final String text;

  AgentTextContent append(String delta) => AgentTextContent('$text$delta');

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'text': text};
}

/// A tool call requested by the model. [arguments] is the best-effort parse of
/// [rawArguments]; the loop revalidates it against the tool schema before use.
class AgentToolCallContent extends AgentContent {
  const AgentToolCallContent({
    required this.id,
    required this.name,
    required this.arguments,
    required this.rawArguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;
  final String rawArguments;

  AgentToolCallContent copyWith({
    Map<String, Object?>? arguments,
    String? rawArguments,
  }) {
    return AgentToolCallContent(
      id: id,
      name: name,
      arguments: arguments ?? this.arguments,
      rawArguments: rawArguments ?? this.rawArguments,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'toolCall',
    'id': id,
    'name': name,
    'arguments': arguments,
    'rawArguments': rawArguments,
  };
}

/// Opaque provider item that must be replayed verbatim to keep a multi-turn
/// tool loop valid (for example an OpenAI Responses `message` item id). Never
/// rendered.
class AgentOpaqueContent extends AgentContent {
  const AgentOpaqueContent({required this.kind, required this.payload});

  final String kind;
  final Map<String, Object?> payload;

  @override
  Map<String, Object?> toJson() => {
    'type': 'opaque',
    'kind': kind,
    'payload': payload,
  };
}

class AgentUsage {
  const AgentUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.totalTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int totalTokens;

  bool get isEmpty => totalTokens == 0 && inputTokens == 0 && outputTokens == 0;

  AgentUsage operator +(AgentUsage other) {
    return AgentUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
      totalTokens: totalTokens + other.totalTokens,
    );
  }
}

sealed class AgentMessage {
  const AgentMessage({required this.timestamp});

  final DateTime timestamp;

  String get role;

  Map<String, Object?> toJson();

  /// Restores a persisted transcript entry. Returns null for rows written by a
  /// newer schema so an unknown role degrades to a shorter transcript instead of
  /// a broken session.
  static AgentMessage? fromJson(Map<String, Object?> json) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      (json['timestamp'] as num?)?.toInt() ?? 0,
      isUtc: true,
    ).toLocal();
    switch (json['role']) {
      case 'user':
        return AgentUserMessage(
          text: json['text'] as String? ?? '',
          timestamp: timestamp,
        );
      case 'assistant':
        final blocks = <AgentContent>[];
        for (final item in (json['content'] as List? ?? const [])) {
          if (item is! Map) continue;
          final block = AgentContent.fromJson(Map<String, Object?>.from(item));
          if (block != null) blocks.add(block);
        }
        return AgentAssistantMessage(
          content: blocks,
          stopReason: AgentStopReason.values.firstWhere(
            (reason) => reason.name == json['stopReason'],
            orElse: () => AgentStopReason.stop,
          ),
          errorMessage: json['errorMessage'] as String?,
          responseId: json['responseId'] as String?,
          timestamp: timestamp,
        );
      case 'toolResult':
        return AgentToolResultMessage(
          toolCallId: json['toolCallId'] as String? ?? '',
          toolName: json['toolName'] as String? ?? '',
          text: json['text'] as String? ?? '',
          isError: json['isError'] as bool? ?? false,
          timestamp: timestamp,
        );
      default:
        return null;
    }
  }
}

class AgentUserMessage extends AgentMessage {
  AgentUserMessage({required this.text, DateTime? timestamp})
    : super(timestamp: timestamp ?? DateTime.now());

  final String text;

  @override
  String get role => 'user';

  @override
  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
  };
}

class AgentAssistantMessage extends AgentMessage {
  AgentAssistantMessage({
    required this.content,
    required this.stopReason,
    this.usage = const AgentUsage(),
    this.errorMessage,
    this.responseId,
    DateTime? timestamp,
  }) : super(timestamp: timestamp ?? DateTime.now());

  final List<AgentContent> content;
  final AgentStopReason stopReason;
  final AgentUsage usage;
  final String? errorMessage;
  final String? responseId;

  @override
  String get role => 'assistant';

  Iterable<AgentToolCallContent> get toolCalls =>
      content.whereType<AgentToolCallContent>();

  String get text =>
      content.whereType<AgentTextContent>().map((block) => block.text).join();

  bool get isFailed =>
      stopReason == AgentStopReason.error ||
      stopReason == AgentStopReason.aborted;

  AgentAssistantMessage copyWith({
    List<AgentContent>? content,
    AgentStopReason? stopReason,
    AgentUsage? usage,
    String? errorMessage,
    String? responseId,
  }) {
    return AgentAssistantMessage(
      content: content ?? this.content,
      stopReason: stopReason ?? this.stopReason,
      usage: usage ?? this.usage,
      errorMessage: errorMessage ?? this.errorMessage,
      responseId: responseId ?? this.responseId,
      timestamp: timestamp,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'role': role,
    'content': [for (final block in content) block.toJson()],
    'stopReason': stopReason.name,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (responseId != null) 'responseId': responseId,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
  };
}

class AgentToolResultMessage extends AgentMessage {
  AgentToolResultMessage({
    required this.toolCallId,
    required this.toolName,
    required this.text,
    required this.isError,
    this.details,
    DateTime? timestamp,
  }) : super(timestamp: timestamp ?? DateTime.now());

  final String toolCallId;
  final String toolName;
  final String text;
  final bool isError;

  /// Structured payload for UI rendering only. Never sent to the provider.
  final Map<String, Object?>? details;

  @override
  String get role => 'toolResult';

  @override
  Map<String, Object?> toJson() => {
    'role': role,
    'toolCallId': toolCallId,
    'toolName': toolName,
    'text': text,
    'isError': isError,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
  };
}
