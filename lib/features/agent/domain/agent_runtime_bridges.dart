import 'agent_tool.dart';

/// Non-secret description of the SSH session the agent is attached to.
///
/// Deliberately flat and primitive: no SSH client, socket, credential or
/// repository reference can travel to the tool layer through this type.
class AgentSessionInfo {
  const AgentSessionInfo({
    required this.hostId,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.connectionState,
    required this.columns,
    required this.rows,
    this.failureMessage,
  });

  final String hostId;

  /// `user@host:port`, used in prompts and the approval card.
  final String label;

  final String host;
  final int port;
  final String username;

  /// Human-readable connection state, e.g. `connected`.
  final String connectionState;

  final int columns;
  final int rows;
  final String? failureMessage;

  bool get isConnected => connectionState == 'connected';
}

class AgentTerminalSnapshot {
  const AgentTerminalSnapshot({
    required this.visible,
    required this.scrollback,
    required this.currentInput,
    required this.columns,
    required this.rows,
  });

  final String visible;
  final String scrollback;

  /// Characters typed on the current prompt line that have not been submitted.
  final String currentInput;

  final int columns;
  final int rows;
}

/// Outcome of one approved command written to the interactive shell.
class AgentShellExecution {
  const AgentShellExecution({
    required this.command,
    required this.output,
    required this.duration,
    required this.timedOut,
  });

  final String command;

  /// Terminal output captured while the command ran, already sanitized.
  final String output;

  final Duration duration;

  /// True when capture stopped at the time limit instead of at an idle shell.
  final bool timedOut;
}

class AgentRemoteEntry {
  const AgentRemoteEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.sizeBytes,
    this.modifiedAt,
    this.permissions,
  });

  final String name;
  final String path;

  /// `file`, `directory`, `symlink` or `other`.
  final String kind;

  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? permissions;
}

class AgentRemoteTextFile {
  const AgentRemoteTextFile({
    required this.path,
    required this.text,
    required this.sizeBytes,
  });

  final String path;
  final String text;
  final int? sizeBytes;
}

class AgentServerStatus {
  const AgentServerStatus({
    required this.loadAverage,
    required this.capturedAt,
    this.hostname,
    this.system,
    this.cpuModel,
    this.cpuCores,
    this.cpuUsage,
    this.memoryTotalBytes,
    this.memoryAvailableBytes,
    this.diskTotalBytes,
    this.diskUsedBytes,
    this.uptime,
  });

  final List<double> loadAverage;
  final DateTime capturedAt;
  final String? hostname;
  final String? system;
  final String? cpuModel;
  final int? cpuCores;
  final double? cpuUsage;
  final int? memoryTotalBytes;
  final int? memoryAvailableBytes;
  final int? diskTotalBytes;
  final int? diskUsedBytes;
  final Duration? uptime;
}

class AgentHistoryEntry {
  const AgentHistoryEntry({
    required this.command,
    required this.startedAt,
    this.exitCode,
    this.duration,
    this.outputExcerpt,
  });

  final String command;
  final DateTime startedAt;
  final int? exitCode;
  final Duration? duration;
  final String? outputExcerpt;
}

class AgentWebSearchResult {
  const AgentWebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

/// Terminal access for the agent. Snapshots are read-only; [runApprovedCommand]
/// is reachable only from the write tool after the user approved the exact text.
abstract interface class AgentTerminalBridge {
  AgentSessionInfo describeSession();

  AgentTerminalSnapshot snapshot({required int scrollbackLines});

  Future<AgentShellExecution> runApprovedCommand(
    String command, {
    required AgentCancellationToken cancellation,
    required Duration timeout,
  });
}

/// Read-only remote filesystem access. No write, delete or rename surface is
/// exposed to the agent at all.
abstract interface class AgentRemoteFileBridge {
  Future<List<AgentRemoteEntry>> listDirectory(String path);

  Future<AgentRemoteEntry> stat(String path);

  Future<AgentRemoteTextFile> readText(String path, {required int maxBytes});
}

abstract interface class AgentServerStatusBridge {
  Future<AgentServerStatus> fetch({
    required AgentCancellationToken cancellation,
  });
}

abstract interface class AgentHistoryBridge {
  Future<List<AgentHistoryEntry>> query({required int limit, String? keyword});
}

/// Web search performed by the app. The endpoint and API key stay on this side
/// of the boundary; the tool only ever receives rendered results.
abstract interface class AgentWebSearchBridge {
  bool get isEnabled;

  int get maxResults;

  Future<List<AgentWebSearchResult>> search(
    String query, {
    required int maxResults,
    required AgentCancellationToken cancellation,
  });
}
