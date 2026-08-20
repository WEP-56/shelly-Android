import '../application/tool_output.dart';
import '../domain/agent_tool.dart';
import 'agent_tool_context.dart';

/// Reads the visible screen, a bounded scrollback and the unsubmitted input.
class TerminalSnapshotTool implements AgentTool {
  const TerminalSnapshotTool(this._context);

  static const _defaultScrollback = 200;
  static const _maxScrollback = 2000;

  final AgentToolContext _context;

  @override
  String get name => 'terminal_snapshot';

  @override
  String get label => '读取终端';

  @override
  String get description =>
      '读取当前 SSH 终端的可见内容、有限滚动缓冲、尚未提交的输入行和终端尺寸。只读，不会向远程发送任何字符。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'scrollback_lines': IntField(
      description: '额外读取的历史行数，0 表示只看当前屏幕，最大 $_maxScrollback。',
      required: false,
      minimum: 0,
      maximum: _maxScrollback,
    ),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final requested = arguments.integer(
      'scrollback_lines',
      fallback: _defaultScrollback,
    );
    final snapshot = _context.terminal.snapshot(
      scrollbackLines: requested.clamp(0, _maxScrollback),
    );
    final visible = ToolOutput.limit(
      ToolOutput.trimTrailingBlankLines(
        ToolOutput.sanitizeTerminal(snapshot.visible),
      ),
      lineLimit: snapshot.rows + 10,
    );
    final scrollback = ToolOutput.limit(
      ToolOutput.trimTrailingBlankLines(
        ToolOutput.sanitizeTerminal(snapshot.scrollback),
      ),
      keepTail: true,
    );
    final text = ToolReport.join([
      ToolReport.fields({
        '终端尺寸': '${snapshot.columns} x ${snapshot.rows}',
        '当前输入行': snapshot.currentInput.isEmpty
            ? '(空)'
            : ToolOutput.sanitizeTerminal(snapshot.currentInput),
      }),
      if (scrollback.text.isNotEmpty)
        ToolReport.section('滚动缓冲（较早）', scrollback.annotated),
      ToolReport.section('当前屏幕', visible.annotated),
    ]);
    return AgentToolResult(text: text);
  }
}

/// Reports connection state and the non-secret identity of the current device.
class SessionStatusTool implements AgentTool {
  const SessionStatusTool(this._context);

  final AgentToolContext _context;

  @override
  String get name => 'session_status';

  @override
  String get label => '读取会话状态';

  @override
  String get description => '读取当前 SSH 会话的连接状态、目标设备、登录用户和终端尺寸。不包含密码、私钥或任何密钥。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => ToolSchema.empty;

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final session = _context.terminal.describeSession();
    return AgentToolResult(
      text: ToolReport.fields({
        '设备': session.label,
        '主机': session.host,
        '端口': session.port,
        '用户': session.username,
        '连接状态': session.connectionState,
        '终端尺寸': '${session.columns} x ${session.rows}',
        '最近失败': session.failureMessage,
      }),
    );
  }
}

/// Reads recent commands for the current device only.
class HistoryQueryTool implements AgentTool {
  const HistoryQueryTool(this._context);

  static const _defaultLimit = 20;
  static const _maxLimit = 100;

  final AgentToolContext _context;

  @override
  String get name => 'history_query';

  @override
  String get label => '查询命令历史';

  @override
  String get description => '查询当前设备的命令历史，包含命令、开始时间、退出码、耗时和受长度限制的输出摘要。只读。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'keyword': StringField(
      description: '按命令文本过滤的关键字，留空表示不过滤。',
      required: false,
    ),
    'limit': IntField(
      description: '返回条数上限，默认 $_defaultLimit，最大 $_maxLimit。',
      required: false,
      minimum: 1,
      maximum: _maxLimit,
    ),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final limit = arguments
        .integer('limit', fallback: _defaultLimit)
        .clamp(1, _maxLimit);
    final keyword = arguments.optionalString('keyword')?.trim();
    final entries = await _context.history.query(
      limit: limit,
      keyword: keyword == null || keyword.isEmpty ? null : keyword,
    );
    cancellation.throwIfCancelled();
    if (entries.isEmpty) {
      return const AgentToolResult(text: '没有匹配的命令历史。');
    }
    final buffer = StringBuffer();
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      buffer.writeln('${index + 1}. ${entry.command}');
      final meta = [
        '时间=${ToolReport.timestamp(entry.startedAt)}',
        if (entry.exitCode != null) '退出码=${entry.exitCode}',
        if (entry.duration != null) '耗时=${ToolReport.duration(entry.duration)}',
      ].join(' ');
      buffer.writeln('   $meta');
      final excerpt = entry.outputExcerpt;
      if (excerpt != null && excerpt.trim().isNotEmpty) {
        final bounded = ToolOutput.limit(
          ToolOutput.sanitizeTerminal(excerpt),
          lineLimit: 12,
          byteLimit: 2048,
          keepTail: true,
        );
        buffer.writeln('   输出摘要: ${bounded.annotated.replaceAll('\n', ' ⏎ ')}');
      }
    }
    final bounded = ToolOutput.limit(buffer.toString());
    return AgentToolResult(text: bounded.annotated);
  }
}

/// Fetches the on-demand server status snapshot.
class ServerStatusTool implements AgentTool {
  const ServerStatusTool(this._context);

  final AgentToolContext _context;

  @override
  String get name => 'server_status';

  @override
  String get label => '读取服务器状态';

  @override
  String get description => '按需读取当前设备的状态快照：主机名、系统、CPU、内存、磁盘、负载和运行时间。只读。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => ToolSchema.empty;

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final status = await _context.status.fetch(cancellation: cancellation);
    cancellation.throwIfCancelled();
    final memoryUsed =
        status.memoryTotalBytes == null || status.memoryAvailableBytes == null
        ? null
        : status.memoryTotalBytes! - status.memoryAvailableBytes!;
    return AgentToolResult(
      text: ToolReport.fields({
        '采集时间': ToolReport.timestamp(status.capturedAt),
        '主机名': status.hostname,
        '系统': status.system,
        'CPU 型号': status.cpuModel,
        'CPU 核心': status.cpuCores,
        'CPU 使用率': ToolReport.percent(status.cpuUsage),
        '内存总量': ToolReport.bytes(status.memoryTotalBytes),
        '内存已用': ToolReport.bytes(memoryUsed),
        '内存可用': ToolReport.bytes(status.memoryAvailableBytes),
        '磁盘总量': ToolReport.bytes(status.diskTotalBytes),
        '磁盘已用': ToolReport.bytes(status.diskUsedBytes),
        '负载': status.loadAverage.isEmpty
            ? ''
            : status.loadAverage.map((value) => value.toString()).join(' / '),
        '运行时间': ToolReport.duration(status.uptime),
      }),
    );
  }
}
