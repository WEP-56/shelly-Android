import '../application/tool_output.dart';
import '../domain/agent_tool.dart';
import 'agent_tool_context.dart';

/// Lists a remote directory over SFTP. Read-only: no create, rename or delete.
class SftpListTool implements AgentTool {
  const SftpListTool(this._context);

  static const _defaultLimit = 200;
  static const _maxLimit = 500;

  final AgentToolContext _context;

  @override
  String get name => 'sftp_list';

  @override
  String get label => '列出远程目录';

  @override
  String get description =>
      '通过 SFTP 列出远程目录内容，返回名称、类型、大小、修改时间和权限。只读，不会写入、改名或删除。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'path': StringField(
      description: '远程绝对路径，例如 /etc 或 /var/log。',
      maxLength: 1024,
    ),
    'limit': IntField(
      description: '返回条目上限，默认 $_defaultLimit，最大 $_maxLimit。',
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
    final path = arguments.string('path').trim();
    final limit = arguments
        .integer('limit', fallback: _defaultLimit)
        .clamp(1, _maxLimit);
    final entries = await _context.files.listDirectory(path);
    cancellation.throwIfCancelled();
    if (entries.isEmpty) {
      return AgentToolResult(text: '$path 是空目录。');
    }
    final sorted = [...entries]
      ..sort((a, b) {
        if (a.kind != b.kind) return a.kind == 'directory' ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    final shown = sorted.take(limit).toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('路径: $path')
      ..writeln(
        '条目: ${entries.length}${shown.length < entries.length ? '（仅列出前 ${shown.length} 条）' : ''}',
      );
    for (final entry in shown) {
      buffer.writeln(
        [
          entry.kind.padRight(9),
          (entry.permissions ?? '').padRight(6),
          ToolReport.bytes(entry.sizeBytes).padLeft(9),
          ToolReport.timestamp(entry.modifiedAt).padRight(20),
          entry.name,
        ].join(' '),
      );
    }
    final bounded = ToolOutput.limit(buffer.toString());
    return AgentToolResult(text: bounded.annotated);
  }
}

/// Reads attributes of one remote path.
class SftpStatTool implements AgentTool {
  const SftpStatTool(this._context);

  final AgentToolContext _context;

  @override
  String get name => 'sftp_stat';

  @override
  String get label => '读取远程属性';

  @override
  String get description => '通过 SFTP 读取一个远程路径的类型、大小、修改时间和权限。只读，不跟随符号链接。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'path': StringField(description: '远程绝对路径。', maxLength: 1024),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final path = arguments.string('path').trim();
    final entry = await _context.files.stat(path);
    return AgentToolResult(
      text: ToolReport.fields({
        '路径': entry.path,
        '名称': entry.name,
        '类型': entry.kind,
        '大小': ToolReport.bytes(entry.sizeBytes),
        '字节数': entry.sizeBytes,
        '修改时间': ToolReport.timestamp(entry.modifiedAt),
        '权限': entry.permissions,
      }),
    );
  }
}

/// Reads a bounded slice of a remote text file.
class SftpReadTextTool implements AgentTool {
  const SftpReadTextTool(this._context);

  static const _maxBytes = 128 * 1024;
  static const _defaultLines = 400;
  static const _maxLines = 2000;

  final AgentToolContext _context;

  @override
  String get name => 'sftp_read_text';

  @override
  String get label => '读取远程文本';

  @override
  String get description =>
      '通过 SFTP 读取远程文本文件内容，受文件大小（128 KB）和行数上限限制。二进制文件会被拒绝。只读。';

  @override
  AgentToolKind get kind => AgentToolKind.read;

  @override
  ToolSchema get schema => const ToolSchema({
    'path': StringField(description: '远程绝对路径。', maxLength: 1024),
    'max_lines': IntField(
      description: '最多返回的行数，默认 $_defaultLines，最大 $_maxLines。',
      required: false,
      minimum: 1,
      maximum: _maxLines,
    ),
    'from_end': BoolField(
      description: 'true 表示读取文件末尾（适合日志），默认 false 表示从开头读取。',
      required: false,
    ),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final path = arguments.string('path').trim();
    final lines = arguments
        .integer('max_lines', fallback: _defaultLines)
        .clamp(1, _maxLines);
    final fromEnd = arguments.boolean('from_end', fallback: false);
    final file = await _context.files.readText(path, maxBytes: _maxBytes);
    cancellation.throwIfCancelled();
    final bounded = ToolOutput.limit(
      file.text,
      lineLimit: lines,
      keepTail: fromEnd,
    );
    return AgentToolResult(
      text: ToolReport.join([
        ToolReport.fields({
          '路径': file.path,
          '大小': ToolReport.bytes(file.sizeBytes),
          '读取方向': fromEnd ? '文件末尾' : '文件开头',
        }),
        ToolReport.section('内容', bounded.annotated),
      ]),
    );
  }
}
