import '../../history/history_repository.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_runtime_bridges.dart';

/// Command history for the agent, scoped to the device the session is attached
/// to. Entries for other hosts are never visible.
class AgentHistoryRuntime implements AgentHistoryBridge {
  AgentHistoryRuntime({
    required HistoryRepository repository,
    required String hostId,
  }) : _repository = repository,
       _hostId = hostId;

  final HistoryRepository _repository;
  final String _hostId;

  @override
  Future<List<AgentHistoryEntry>> query({
    required int limit,
    String? keyword,
  }) async {
    try {
      final entries = await _repository.list(hostId: _hostId, query: keyword);
      return [
        for (final entry in entries.take(limit))
          AgentHistoryEntry(
            command: entry.command,
            startedAt: entry.startedAt,
            exitCode: entry.exitCode,
            duration: entry.duration,
            outputExcerpt: entry.outputExcerpt,
          ),
      ];
    } on HistoryRepositoryException catch (failure) {
      throw AgentToolException(failure.message);
    }
  }
}
