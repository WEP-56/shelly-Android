import '../domain/agent_tool.dart';
import 'agent_tool_context.dart';
import 'read_tools.dart';
import 'request_commands_tool.dart';
import 'sftp_tools.dart';
import 'web_search_tool.dart';

/// The tool inventory handed to the provider for one run.
///
/// Exactly one write tool exists ([RequestCommandsTool]); everything else is
/// read-only. `web_search` only appears when the user configured it, so the
/// model is never told about a tool that cannot work.
class AgentToolSet {
  AgentToolSet(AgentToolContext context)
    : tools = List.unmodifiable([
        TerminalSnapshotTool(context),
        SessionStatusTool(context),
        ServerStatusTool(context),
        HistoryQueryTool(context),
        SftpListTool(context),
        SftpStatTool(context),
        SftpReadTextTool(context),
        if (context.webSearch.isEnabled) WebSearchTool(context),
        RequestCommandsTool(context),
      ]) {
    for (final tool in tools) {
      _byName[tool.name] = tool;
    }
  }

  final List<AgentTool> tools;
  final Map<String, AgentTool> _byName = {};

  AgentTool? find(String name) => _byName[name];

  Iterable<AgentTool> get readTools =>
      tools.where((tool) => tool.kind == AgentToolKind.read);

  Iterable<AgentTool> get writeTools =>
      tools.where((tool) => tool.kind == AgentToolKind.write);
}
