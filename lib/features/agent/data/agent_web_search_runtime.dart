import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/agent_failure.dart';
import '../domain/agent_provider_config.dart';
import '../domain/agent_runtime_bridges.dart';
import '../domain/agent_tool.dart';
import 'agent_settings_repository.dart';

/// Web search performed by the app, not by the model.
///
/// The endpoint and the API key never leave this class: the key is read from
/// secure storage per request, put into the `Authorization` header, and dropped
/// when the request finishes. Failures report the status code only, so no
/// request or response text that might echo the key reaches the model.
class AgentWebSearchRuntime implements AgentWebSearchBridge {
  AgentWebSearchRuntime({
    required AgentSettingsRepository settings,
    required WebSearchConfig config,
    http.Client Function()? clientFactory,
  }) : _settings = settings,
       _config = config,
       _clientFactory = clientFactory ?? http.Client.new;

  static const _maxSnippetChars = 2000;

  final AgentSettingsRepository _settings;
  final WebSearchConfig _config;
  final http.Client Function() _clientFactory;

  @override
  bool get isEnabled => _config.isUsable;

  @override
  int get maxResults => _config.maxResults;

  @override
  Future<List<AgentWebSearchResult>> search(
    String query, {
    required int maxResults,
    required AgentCancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    if (!_config.isUsable) {
      throw const AgentToolException('Web Search 未启用或未配置完整，请让用户在设置里检查。');
    }
    final uri = Uri.tryParse(_config.endpoint.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const AgentToolException('Web Search 接口地址无效，请让用户在设置里修正。');
    }
    final apiKey = await _readKey();
    final client = _clientFactory();
    var closed = false;
    var timedOut = false;
    void closeClient() {
      if (closed) return;
      closed = true;
      client.close();
    }

    cancellation.addListener(closeClient);
    final deadline = Timer(_config.timeout, () {
      timedOut = true;
      closeClient();
    });
    try {
      final response = await client.post(
        uri,
        headers: {
          'authorization': 'Bearer $apiKey',
          'content-type': 'application/json',
          'accept': 'application/json',
        },
        body: jsonEncode({'query': query, 'max_results': maxResults}),
      );
      cancellation.throwIfCancelled();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AgentToolException(_statusMessage(response.statusCode));
      }
      return _parse(response.bodyBytes, maxResults);
    } on AgentToolException {
      rethrow;
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      if (cancellation.isCancelled) {
        throw const AgentFailure(
          stage: AgentFailureStage.cancelled,
          message: '用户停止了本轮运行。',
        );
      }
      if (timedOut) {
        throw AgentToolException(
          '搜索请求超时（${_config.timeout.inSeconds}s），本次没有拿到结果。',
        );
      }
      throw AgentToolException('无法连接搜索服务：${_transportMessage(error)}');
    } finally {
      deadline.cancel();
      closeClient();
    }
  }

  Future<String> _readKey() async {
    try {
      final key = await _settings.readWebSearchKey(_config);
      if (key == null) {
        throw const AgentToolException('Web Search 缺少 API Key，请让用户在设置里补上。');
      }
      return key;
    } on AgentSettingsException catch (error) {
      throw AgentToolException(error.message);
    }
  }

  /// Parses a Tavily-shaped response: a `results` array whose items carry
  /// `title`, `url` and the snippet in `content` (or `snippet`).
  static List<AgentWebSearchResult> _parse(List<int> bytes, int maxResults) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      throw const AgentToolException('搜索服务返回的内容不是合法 JSON，本次没有拿到结果。');
    }
    if (json is! Map) {
      throw const AgentToolException('搜索服务返回的结构无法解析，本次没有拿到结果。');
    }
    final results = json['results'];
    if (results is! List) {
      throw const AgentToolException('搜索服务没有返回 results 列表，本次没有拿到结果。');
    }
    final parsed = <AgentWebSearchResult>[];
    for (final item in results) {
      if (parsed.length >= maxResults) break;
      if (item is! Map) continue;
      final url = _text(item['url']);
      if (url.isEmpty) continue;
      final snippet = _text(item['content']).isNotEmpty
          ? _text(item['content'])
          : _text(item['snippet']);
      parsed.add(
        AgentWebSearchResult(
          title: _text(item['title']).isEmpty ? url : _text(item['title']),
          url: url,
          snippet: snippet.length <= _maxSnippetChars
              ? snippet
              : '${snippet.substring(0, _maxSnippetChars)}…',
        ),
      );
    }
    return parsed;
  }

  static String _text(Object? value) =>
      value is String ? value.trim() : (value == null ? '' : value.toString());

  static String _statusMessage(int status) => switch (status) {
    400 => '搜索请求被拒绝（400），请让用户检查 Web Search 接口配置。',
    401 || 403 => '搜索服务拒绝授权（$status），API Key 可能无效或额度不足。',
    404 => '搜索接口地址不存在（404），请让用户检查配置。',
    429 => '搜索请求过于频繁或额度不足（429），稍后再试。',
    _ when status >= 500 => '搜索服务暂时不可用（$status），稍后再试。',
    _ => '搜索请求失败（$status）。',
  };

  static String _transportMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('failed host lookup')) return '域名无法解析';
    if (text.contains('connection refused')) return '连接被拒绝';
    if (text.contains('handshake')) return 'TLS 握手失败';
    if (text.contains('timeout') || text.contains('timed out')) return '连接超时';
    return '网络不可用';
  }
}
