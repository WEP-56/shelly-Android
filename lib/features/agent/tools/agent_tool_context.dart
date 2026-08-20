import '../domain/agent_command_approval.dart';
import '../domain/agent_runtime_bridges.dart';

/// Everything the tool layer is allowed to touch.
///
/// Only narrow bridges appear here: no [SshSessionController], SFTP client,
/// credential store or provider config, so a tool cannot reach a secret even by
/// mistake.
class AgentToolContext {
  const AgentToolContext({
    required this.terminal,
    required this.files,
    required this.status,
    required this.history,
    required this.webSearch,
    required this.approvals,
  });

  final AgentTerminalBridge terminal;
  final AgentRemoteFileBridge files;
  final AgentServerStatusBridge status;
  final AgentHistoryBridge history;
  final AgentWebSearchBridge webSearch;
  final AgentApprovalGateway approvals;
}

/// Small formatting helpers shared by the tools so every result reads the same.
abstract final class ToolReport {
  static String fields(Map<String, Object?> values) {
    final buffer = StringBuffer();
    for (final entry in values.entries) {
      final value = entry.value;
      if (value == null) continue;
      final text = value is String ? value.trim() : value.toString();
      if (text.isEmpty) continue;
      buffer.writeln('${entry.key}: $text');
    }
    return buffer.toString().trimRight();
  }

  static String section(String title, String body) {
    final trimmed = body.trimRight();
    if (trimmed.isEmpty) return '## $title\n(空)';
    return '## $title\n$trimmed';
  }

  static String join(List<String> parts) =>
      parts.where((part) => part.trim().isNotEmpty).join('\n\n');

  static String bytes(int? value) {
    if (value == null) return '';
    if (value < 1024) return '$value B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
  }

  static String percent(double? value) =>
      value == null ? '' : '${(value * 100).toStringAsFixed(1)}%';

  static String duration(Duration? value) {
    if (value == null) return '';
    final days = value.inDays;
    final hours = value.inHours % 24;
    final minutes = value.inMinutes % 60;
    final seconds = value.inSeconds % 60;
    if (days > 0) return '${days}d ${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${value.inMilliseconds}ms';
  }

  static String timestamp(DateTime? value) =>
      value == null ? '' : value.toLocal().toIso8601String();
}
