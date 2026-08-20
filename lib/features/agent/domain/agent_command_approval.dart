import 'package:uuid/uuid.dart';

enum AgentCommandDecision { pending, approved, rejected }

/// Execution phase of an approved command, used by the transcript UI.
enum AgentCommandPhase { waiting, running, finished, failed, skipped }

/// One command slot inside an approval record.
class AgentCommandDraft {
  const AgentCommandDraft({
    required this.id,
    required this.command,
    this.decision = AgentCommandDecision.pending,
    this.phase = AgentCommandPhase.waiting,
    this.edited = false,
  });

  final String id;

  /// Raw command text. Exactly this string is written to the shell once
  /// approved; the app never appends, wraps or splits it.
  final String command;

  final AgentCommandDecision decision;
  final AgentCommandPhase phase;

  /// True when the user rewrote the model's original text.
  final bool edited;

  AgentCommandDraft copyWith({
    String? command,
    AgentCommandDecision? decision,
    AgentCommandPhase? phase,
    bool? edited,
  }) {
    return AgentCommandDraft(
      id: id,
      command: command ?? this.command,
      decision: decision ?? this.decision,
      phase: phase ?? this.phase,
      edited: edited ?? this.edited,
    );
  }
}

/// An immutable command-approval record.
///
/// Editing a command does not mutate a record: the controller replaces it with a
/// new record that carries a fresh [id] and points at the old one through
/// [supersedes], so the approval trail always shows what was actually approved.
class AgentCommandApproval {
  const AgentCommandApproval({
    required this.id,
    required this.toolCallId,
    required this.hostLabel,
    required this.reason,
    required this.expectedResult,
    required this.commands,
    required this.createdAt,
    this.supersedes,
    this.executing = false,
    this.settled = false,
  });

  factory AgentCommandApproval.create({
    required String toolCallId,
    required String hostLabel,
    required String reason,
    required String expectedResult,
    required List<String> commands,
    Uuid? uuid,
  }) {
    final generator = uuid ?? const Uuid();
    return AgentCommandApproval(
      id: generator.v4(),
      toolCallId: toolCallId,
      hostLabel: hostLabel,
      reason: reason,
      expectedResult: expectedResult,
      commands: [
        for (final command in commands)
          AgentCommandDraft(id: generator.v4(), command: command),
      ],
      createdAt: DateTime.now(),
    );
  }

  final String id;
  final String toolCallId;

  /// Target device shown on the approval card.
  final String hostLabel;

  final String reason;
  final String expectedResult;
  final List<AgentCommandDraft> commands;
  final DateTime createdAt;

  /// Id of the record this one replaced after an edit.
  final String? supersedes;

  final bool executing;
  final bool settled;

  bool get isDecided =>
      commands.every((draft) => draft.decision != AgentCommandDecision.pending);

  bool get hasApproved =>
      commands.any((draft) => draft.decision == AgentCommandDecision.approved);

  Iterable<AgentCommandDraft> get approved => commands.where(
    (draft) => draft.decision == AgentCommandDecision.approved,
  );

  AgentCommandApproval copyWith({
    List<AgentCommandDraft>? commands,
    bool? executing,
    bool? settled,
  }) {
    return AgentCommandApproval(
      id: id,
      toolCallId: toolCallId,
      hostLabel: hostLabel,
      reason: reason,
      expectedResult: expectedResult,
      commands: commands ?? this.commands,
      createdAt: createdAt,
      supersedes: supersedes,
      executing: executing ?? this.executing,
      settled: settled ?? this.settled,
    );
  }

  /// Builds the replacement record required when a command is edited.
  AgentCommandApproval replaceCommand(
    String commandId,
    String command, {
    Uuid? uuid,
  }) {
    final generator = uuid ?? const Uuid();
    return AgentCommandApproval(
      id: generator.v4(),
      toolCallId: toolCallId,
      hostLabel: hostLabel,
      reason: reason,
      expectedResult: expectedResult,
      commands: [
        for (final draft in commands)
          if (draft.id == commandId)
            AgentCommandDraft(
              id: generator.v4(),
              command: command,
              edited: true,
            )
          else
            AgentCommandDraft(
              id: draft.id,
              command: draft.command,
              edited: draft.edited,
            ),
      ],
      createdAt: DateTime.now(),
      supersedes: id,
    );
  }

  AgentCommandApproval decide(String commandId, AgentCommandDecision decision) {
    return copyWith(
      commands: [
        for (final draft in commands)
          draft.id == commandId ? draft.copyWith(decision: decision) : draft,
      ],
    );
  }

  AgentCommandApproval decideAll(AgentCommandDecision decision) {
    return copyWith(
      commands: [
        for (final draft in commands) draft.copyWith(decision: decision),
      ],
    );
  }

  AgentCommandApproval withPhase(String commandId, AgentCommandPhase phase) {
    return copyWith(
      commands: [
        for (final draft in commands)
          draft.id == commandId ? draft.copyWith(phase: phase) : draft,
      ],
    );
  }
}

/// The decision the user reached, handed back to the write tool.
class AgentApprovalOutcome {
  const AgentApprovalOutcome({
    required this.approvalId,
    required this.commands,
    required this.cancelled,
  });

  const AgentApprovalOutcome.cancelled(this.approvalId)
    : commands = const [],
      cancelled = true;

  final String approvalId;

  /// Every command slot with its final decision, in the order presented.
  final List<AgentCommandDraft> commands;

  final bool cancelled;
}

/// Bridge between the write tool and the UI approval boundary.
abstract interface class AgentApprovalGateway {
  /// Publishes [approval] and completes once every command has a decision, or
  /// immediately with a cancelled outcome when the run is stopped.
  Future<AgentApprovalOutcome> requestApproval(AgentCommandApproval approval);

  /// Reports execution progress of an approved command so the card can show it.
  void reportCommandPhase(
    String approvalId,
    String commandId,
    AgentCommandPhase phase,
  );

  /// Releases the approval card once the write tool is done with it.
  void finishApproval(String approvalId);
}
