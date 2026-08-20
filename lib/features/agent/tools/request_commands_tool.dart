import '../application/tool_output.dart';
import '../domain/agent_command_approval.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_tool.dart';
import 'agent_tool_context.dart';

/// The only tool in the app that can change the remote host.
///
/// It never writes to the shell itself: it publishes an approval record, waits
/// for the user's decision on every single command, and only then hands the
/// exact approved text to [AgentTerminalBridge.runApprovedCommand]. Rejections
/// and cancellations come back as ordinary tool results so the loop can react
/// instead of dying.
class RequestCommandsTool implements AgentTool {
  const RequestCommandsTool(this._context);

  /// Stable tool name, also used by the transcript UI to pair a result with the
  /// approval record it came from.
  static const toolName = 'request_commands';

  static const _maxCommands = 8;
  static const _maxCommandLength = 2000;
  static const _commandTimeout = Duration(seconds: 120);
  static const _outputLines = 400;
  static const _outputBytes = 24 * 1024;

  final AgentToolContext _context;

  @override
  String get name => toolName;

  @override
  String get label => '申请执行命令';

  @override
  String get description =>
      '向用户申请在当前设备上执行一条或多条完整命令。必须说明原因和预期结果。用户逐条批准后，应用把原文写入终端并把受限输出回传给你；用户可以拒绝或修改，修改后会生成新的审批记录。这是唯一能改变远程主机的工具。';

  @override
  AgentToolKind get kind => AgentToolKind.write;

  @override
  ToolSchema get schema => const ToolSchema({
    'commands': StringListField(
      description: '要执行的完整命令，按执行顺序排列。每项必须可以直接粘贴到 shell 运行，不要写占位符或省略号。',
      maxItems: _maxCommands,
      itemMaxLength: _maxCommandLength,
    ),
    'reason': StringField(
      description: '为什么需要执行这些命令，一到两句话，用户会直接看到。',
      maxLength: 600,
    ),
    'expected_result': StringField(
      description: '预期结果或影响，说明会读到什么、改动什么，用户会直接看到。',
      maxLength: 600,
    ),
  });

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final session = _context.terminal.describeSession();
    if (!session.isConnected) {
      return AgentToolResult(
        text: '当前会话未连接（状态: ${session.connectionState}），无法执行命令。请先让用户恢复连接。',
        isError: true,
      );
    }
    final commands = arguments.stringList('commands');
    final reason = arguments.string('reason').trim();
    final expected = arguments.string('expected_result').trim();
    final approval = AgentCommandApproval.create(
      toolCallId: toolCallId,
      hostLabel: session.label,
      reason: reason,
      expectedResult: expected,
      commands: [for (final command in commands) command.trim()],
    );

    final outcome = await _context.approvals.requestApproval(approval);
    if (outcome.cancelled) {
      return const AgentToolResult(text: '用户已停止本次运行，没有任何命令被执行。', isError: true);
    }
    try {
      return await _runDecided(outcome, cancellation);
    } finally {
      _context.approvals.finishApproval(outcome.approvalId);
    }
  }

  Future<AgentToolResult> _runDecided(
    AgentApprovalOutcome outcome,
    AgentCancellationToken cancellation,
  ) async {
    final sections = <String>[];
    var executed = 0;
    var rejected = 0;
    var skipped = 0;
    var failed = 0;

    for (final draft in outcome.commands) {
      if (draft.decision != AgentCommandDecision.approved) {
        rejected++;
        _context.approvals.reportCommandPhase(
          outcome.approvalId,
          draft.id,
          AgentCommandPhase.skipped,
        );
        sections.add(
          ToolReport.section(
            '已拒绝: ${draft.command}',
            '用户拒绝执行这条命令。不要重试同一条命令，请换方案或先解释原因。',
          ),
        );
        continue;
      }
      if (cancellation.isCancelled) {
        skipped++;
        _context.approvals.reportCommandPhase(
          outcome.approvalId,
          draft.id,
          AgentCommandPhase.skipped,
        );
        sections.add(
          ToolReport.section('未执行: ${draft.command}', '用户在这条命令之前停止了运行。'),
        );
        continue;
      }
      _context.approvals.reportCommandPhase(
        outcome.approvalId,
        draft.id,
        AgentCommandPhase.running,
      );
      try {
        final execution = await _context.terminal.runApprovedCommand(
          draft.command,
          cancellation: cancellation,
          timeout: _commandTimeout,
        );
        executed++;
        _context.approvals.reportCommandPhase(
          outcome.approvalId,
          draft.id,
          AgentCommandPhase.finished,
        );
        final bounded = ToolOutput.limit(
          ToolOutput.trimTrailingBlankLines(
            ToolOutput.sanitizeTerminal(execution.output),
          ),
          lineLimit: _outputLines,
          byteLimit: _outputBytes,
          keepTail: true,
        );
        sections.add(
          ToolReport.section(
            '已执行: ${draft.command}',
            ToolReport.join([
              ToolReport.fields({
                '耗时': ToolReport.duration(execution.duration),
                '采集': execution.timedOut
                    ? '达到 ${_commandTimeout.inSeconds}s 上限时停止采集，命令可能仍在运行'
                    : '命令结束后停止采集',
                '退出码': '不可知（命令在交互式终端中运行，应用不会追加任何未批准的字符）',
              }),
              ToolReport.section('输出', bounded.annotated),
            ]),
          ),
        );
      } on AgentFailure catch (failure) {
        _context.approvals.reportCommandPhase(
          outcome.approvalId,
          draft.id,
          failure.isCancelled
              ? AgentCommandPhase.skipped
              : AgentCommandPhase.failed,
        );
        if (failure.isCancelled) {
          skipped++;
          sections.add(
            ToolReport.section(
              '已取消: ${draft.command}',
              '用户在这条命令执行中停止了运行，结果不完整。',
            ),
          );
        } else {
          failed++;
          sections.add(
            ToolReport.section('执行失败: ${draft.command}', failure.message),
          );
        }
      } on AgentToolException catch (error) {
        failed++;
        _context.approvals.reportCommandPhase(
          outcome.approvalId,
          draft.id,
          AgentCommandPhase.failed,
        );
        sections.add(
          ToolReport.section('执行失败: ${draft.command}', error.message),
        );
      }
    }

    final summary = ToolReport.fields({
      '设备': _context.terminal.describeSession().label,
      '已执行': executed,
      '被拒绝': rejected == 0 ? null : rejected,
      '未执行': skipped == 0 ? null : skipped,
      '失败': failed == 0 ? null : failed,
    });
    final text = ToolReport.join([summary, ...sections]);
    return AgentToolResult(
      text: text.isEmpty ? '没有命令被执行。' : text,
      isError: executed == 0 && (rejected > 0 || failed > 0 || skipped > 0),
    );
  }
}
