import '../../server_status/server_status_service.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_runtime_bridges.dart';
import '../domain/agent_tool.dart';

/// Server status for the agent, reusing the same snapshot service the status
/// dialog uses so both surfaces report identical numbers.
class AgentServerStatusRuntime implements AgentServerStatusBridge {
  AgentServerStatusRuntime(this._service);

  final ServerStatusService _service;

  @override
  Future<AgentServerStatus> fetch({
    required AgentCancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final token = ServerStatusCancellationToken();
    cancellation.addListener(token.cancel);
    try {
      return _convert(await _service.fetch(cancellationToken: token));
    } on ServerStatusCancelled {
      throw const AgentFailure(
        stage: AgentFailureStage.cancelled,
        message: '用户停止了本轮运行。',
      );
    } on ServerStatusException catch (error) {
      throw AgentToolException(error.message);
    }
  }

  static AgentServerStatus _convert(ServerStatusSnapshot snapshot) {
    return AgentServerStatus(
      loadAverage: snapshot.loadAverage,
      capturedAt: snapshot.capturedAt,
      hostname: snapshot.hostname,
      system: snapshot.system,
      cpuModel: snapshot.cpu.model,
      cpuCores: snapshot.cpu.cores,
      cpuUsage: snapshot.cpu.usage,
      memoryTotalBytes: snapshot.memory.totalBytes,
      memoryAvailableBytes: snapshot.memory.availableBytes,
      diskTotalBytes: snapshot.disk.totalBytes,
      diskUsedBytes: snapshot.disk.usedBytes,
      uptime: snapshot.uptime,
    );
  }
}
