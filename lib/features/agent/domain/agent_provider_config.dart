import 'package:uuid/uuid.dart';

/// Wire protocol of a provider endpoint.
///
/// `messages` is the Anthropic Messages shape (`POST /v1/messages`, SSE with
/// `message_start`/`content_block_delta`/`message_delta`).
/// `responses` is the OpenAI Responses shape (`POST /v1/responses`, SSE with
/// `response.output_item.added`/`response.output_text.delta`/`response.completed`).
enum AgentProviderProtocol {
  messages('messages', 'Messages', 'Anthropic Messages'),
  responses('responses', 'Responses', 'OpenAI Responses');

  const AgentProviderProtocol(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AgentProviderProtocol fromId(String? id) {
    return AgentProviderProtocol.values.firstWhere(
      (protocol) => protocol.id == id,
      orElse: () => AgentProviderProtocol.messages,
    );
  }
}

class AgentProviderConfig {
  const AgentProviderConfig({
    required this.id,
    required this.name,
    required this.protocol,
    required this.endpoint,
    required this.model,
    required this.credentialRef,
    required this.timeout,
    required this.maxLoops,
    required this.maxOutputTokens,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
  });

  static const defaultTimeout = Duration(seconds: 120);
  static const defaultMaxLoops = 12;
  static const defaultMaxOutputTokens = 4096;

  final String id;
  final String name;
  final AgentProviderProtocol protocol;

  /// Base URL without the protocol-specific path, e.g. `https://api.anthropic.com`.
  final String endpoint;

  final String model;

  /// Secure-storage reference for the API key. Never the key itself.
  final String? credentialRef;

  final Duration timeout;
  final int maxLoops;
  final int maxOutputTokens;
  final bool isDefault;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasApiKey => credentialRef != null;

  String get summary => '${protocol.label} · $model';

  /// Full request URL for this protocol.
  ///
  /// Endpoints are written by hand, so all three common shapes are accepted:
  /// a bare host (`https://api.example.com`), a versioned base URL as printed by
  /// most gateways (`https://api.example.com/v1`), and the concrete path
  /// (`https://api.example.com/v1/messages`). Only the missing part is appended —
  /// a versioned base must not become `/v1/v1/messages`, which every gateway
  /// answers with 404.
  Uri get requestUri => Uri.parse(resolveRequestUrl(endpoint, protocol));

  /// Same join as [requestUri] but usable on a draft, so the form can show the
  /// exact URL that will be called before anything is saved.
  static String resolveRequestUrl(
    String endpoint,
    AgentProviderProtocol protocol,
  ) {
    final trimmed = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return '';
    final leaf = switch (protocol) {
      AgentProviderProtocol.messages => 'messages',
      AgentProviderProtocol.responses => 'responses',
    };
    final lower = trimmed.toLowerCase();
    if (lower.endsWith('/$leaf')) return trimmed;
    if (_versionSuffix.hasMatch(lower)) return '$trimmed/$leaf';
    return '$trimmed/v1/$leaf';
  }

  static final _versionSuffix = RegExp(r'/v\d+$');

  AgentProviderConfig copyWith({
    String? name,
    AgentProviderProtocol? protocol,
    String? endpoint,
    String? model,
    String? credentialRef,
    Duration? timeout,
    int? maxLoops,
    int? maxOutputTokens,
    bool? isDefault,
    DateTime? updatedAt,
  }) {
    return AgentProviderConfig(
      id: id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      endpoint: endpoint ?? this.endpoint,
      model: model ?? this.model,
      credentialRef: credentialRef ?? this.credentialRef,
      timeout: timeout ?? this.timeout,
      maxLoops: maxLoops ?? this.maxLoops,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// User-editable fields of a provider. The API key lives in [apiKey] only while
/// the form is open; the repository moves it straight into secure storage.
class AgentProviderDraft {
  const AgentProviderDraft({
    required this.name,
    required this.protocol,
    required this.endpoint,
    required this.model,
    required this.timeout,
    required this.maxLoops,
    required this.maxOutputTokens,
    this.apiKey,
  });

  final String name;
  final AgentProviderProtocol protocol;
  final String endpoint;
  final String model;
  final Duration timeout;
  final int maxLoops;
  final int maxOutputTokens;
  final String? apiKey;
}

/// Web Search is a separate provider: the app performs the request and injects
/// the results, so the model never sees the search key.
class WebSearchConfig {
  const WebSearchConfig({
    this.enabled = false,
    this.endpoint = '',
    this.credentialRef,
    this.timeout = const Duration(seconds: 20),
    this.maxResults = 5,
  });

  final bool enabled;
  final String endpoint;
  final String? credentialRef;
  final Duration timeout;
  final int maxResults;

  bool get isUsable =>
      enabled && endpoint.trim().isNotEmpty && credentialRef != null;

  WebSearchConfig copyWith({
    bool? enabled,
    String? endpoint,
    String? credentialRef,
    Duration? timeout,
    int? maxResults,
  }) {
    return WebSearchConfig(
      enabled: enabled ?? this.enabled,
      endpoint: endpoint ?? this.endpoint,
      credentialRef: credentialRef ?? this.credentialRef,
      timeout: timeout ?? this.timeout,
      maxResults: maxResults ?? this.maxResults,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'endpoint': endpoint,
    'credentialRef': credentialRef,
    'timeoutMs': timeout.inMilliseconds,
    'maxResults': maxResults,
  };

  factory WebSearchConfig.fromJson(Map<String, Object?> json) {
    return WebSearchConfig(
      enabled: json['enabled'] as bool? ?? false,
      endpoint: json['endpoint'] as String? ?? '',
      credentialRef: json['credentialRef'] as String?,
      timeout: Duration(
        milliseconds: (json['timeoutMs'] as num?)?.toInt() ?? 20000,
      ),
      maxResults: (json['maxResults'] as num?)?.toInt() ?? 5,
    );
  }
}

String newAgentCredentialRef([Uuid? uuid]) =>
    'agent-provider-${(uuid ?? const Uuid()).v4()}';
