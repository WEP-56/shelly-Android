import '../application/tool_output.dart';
import '../domain/agent_tool.dart';
import 'agent_tool_context.dart';

/// Searches the web through the app-owned search bridge.
///
/// The endpoint and API key stay inside the app: the model only ever receives
/// rendered titles, URLs and snippets, and can never read the search key.
class WebSearchTool implements AgentTool {
  const WebSearchTool(this._context);

  static const _snippetLines = 6;
  static const _snippetBytes = 1200;

  final AgentToolContext _context;

  @override
  String get name => 'web_search';

  @override
  String get label => '联网搜索';

  @override
  String get description =>
      '通过应用配置的搜索服务查询公开资料，返回标题、链接和摘要。用于查证命令用法、报错信息或软件版本；搜索由应用执行，密钥不会进入对话。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'query': StringField(description: '搜索关键词，使用自然语言或报错原文。', maxLength: 512),
    'max_results': IntField(
      description: '返回结果条数上限，默认使用设置中的值。',
      required: false,
      minimum: 1,
      maximum: 10,
    ),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (!_context.webSearch.isEnabled) {
      return const AgentToolResult(
        text: '联网搜索未启用。请让用户在设置中开启 Web Search 并填入服务地址和密钥，或改用本机命令与只读工具求证。',
        isError: true,
      );
    }
    final query = arguments.string('query').trim();
    if (query.isEmpty) {
      return const AgentToolResult(text: '搜索关键词不能为空。', isError: true);
    }
    final configured = _context.webSearch.maxResults;
    final requested = arguments
        .integer('max_results', fallback: configured)
        .clamp(1, configured < 1 ? 1 : configured);
    final results = await _context.webSearch.search(
      query,
      maxResults: requested,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();
    if (results.isEmpty) {
      return AgentToolResult(text: '“$query”没有搜索结果。');
    }
    final buffer = StringBuffer()..writeln('查询: $query');
    for (var index = 0; index < results.length; index++) {
      final result = results[index];
      buffer.writeln();
      buffer.writeln('${index + 1}. ${result.title}');
      buffer.writeln('   ${result.url}');
      final snippet = result.snippet.trim();
      if (snippet.isNotEmpty) {
        final bounded = ToolOutput.limit(
          snippet,
          lineLimit: _snippetLines,
          byteLimit: _snippetBytes,
        );
        for (final line in bounded.annotated.split('\n')) {
          buffer.writeln('   $line');
        }
      }
    }
    final bounded = ToolOutput.limit(buffer.toString());
    return AgentToolResult(text: bounded.annotated);
  }
}
