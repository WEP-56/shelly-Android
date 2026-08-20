import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../app/models.dart';
import '../../../core/ssh/ssh_session_controller.dart';
import '../../../core/terminal/terminal_session_adapter.dart';
import '../../history/history_repository.dart';
import '../../server_status/server_status_service.dart';
import '../data/agent_history_runtime.dart';
import '../data/agent_remote_file_runtime.dart';
import '../data/agent_server_status_runtime.dart';
import '../data/agent_session_repository.dart';
import '../data/agent_settings_repository.dart';
import '../data/agent_terminal_runtime.dart';
import '../data/agent_web_search_runtime.dart';
import '../domain/agent_command_approval.dart';
import '../domain/agent_event.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_message.dart';
import '../domain/agent_provider_config.dart';
import '../provider/agent_provider.dart';
import '../provider/messages_provider.dart';
import '../provider/responses_provider.dart';
import '../tools/agent_tool_context.dart';
import '../tools/agent_tool_set.dart';
import 'agent_loop.dart';
import 'agent_system_prompt.dart';

/// A read tool currently running, shown as a transient row in the transcript.
class AgentActiveTool {
  const AgentActiveTool({
    required this.toolCallId,
    required this.toolName,
    required this.label,
  });

  final String toolCallId;
  final String toolName;
  final String label;
}

/// Owns one agent conversation for one SSH session.
///
/// It is also the approval boundary: [requestApproval] publishes the record the
/// UI renders and the run stays parked until the user decides every command, so
/// nothing reaches the shell without an explicit tap. Provider API keys are read
/// per run straight into [AgentLoop] and never stored on this object.
class AgentController extends ChangeNotifier implements AgentApprovalGateway {
  AgentController({
    required HostProfile host,
    required SshSessionController session,
    required TerminalSessionAdapter adapter,
    required AgentSettingsRepository settings,
    required AgentSessionRepository sessions,
    required HistoryRepository history,
    AgentProvider Function(AgentProviderProtocol protocol)? providerFactory,
  }) : _host = host,
       _settings = settings,
       _sessionStore = sessions,
       _providerFactory = providerFactory ?? _defaultProviderFactory,
       _terminal = AgentTerminalRuntime(
         host: host,
         session: session,
         adapter: adapter,
       ),
       _files = AgentRemoteFileRuntime(session),
       _serverStatus = AgentServerStatusRuntime(ServerStatusService(session)),
       _historyBridge = AgentHistoryRuntime(
         repository: history,
         hostId: host.id,
       );

  final HostProfile _host;
  final AgentSettingsRepository _settings;
  final AgentSessionRepository _sessionStore;
  final AgentProvider Function(AgentProviderProtocol protocol) _providerFactory;
  final AgentTerminalRuntime _terminal;
  final AgentRemoteFileRuntime _files;
  final AgentServerStatusRuntime _serverStatus;
  final AgentHistoryRuntime _historyBridge;

  final List<AgentMessage> _messages = [];
  final Map<String, List<AgentCommandApproval>> _approvals = {};

  bool _loading = true;
  bool _running = false;
  bool _disposed = false;
  String? _error;
  AgentProviderConfig? _provider;
  WebSearchConfig _webSearch = const WebSearchConfig();
  String _workSpec = '';
  List<AgentSessionSummary> _sessionList = const [];
  AgentSessionSummary? _current;
  AgentAssistantMessage? _streaming;
  AgentStatus? _status;
  AgentActiveTool? _activeTool;
  AgentUsage _usage = const AgentUsage();
  AgentCommandApproval? _pending;
  Completer<AgentApprovalOutcome>? _approvalCompleter;
  AgentToolSet? _toolSet;
  AgentLoop? _loop;
  StreamSubscription<AgentRuntimeEvent>? _subscription;

  bool get isLoading => _loading;
  bool get isRunning => _running;
  String? get error => _error;
  AgentProviderConfig? get provider => _provider;
  bool get isConfigured => _provider != null && _provider!.hasApiKey;
  WebSearchConfig get webSearch => _webSearch;
  String get workSpec => _workSpec;
  List<AgentSessionSummary> get sessions => _sessionList;
  AgentSessionSummary? get currentSession => _current;
  List<AgentMessage> get messages => List.unmodifiable(_messages);
  AgentAssistantMessage? get streamingMessage => _streaming;
  AgentStatus? get status => _status;
  AgentActiveTool? get activeTool => _activeTool;
  AgentUsage get usage => _usage;
  AgentCommandApproval? get pendingApproval => _pending;

  /// Every approval record ever published for [toolCallId], oldest first, so the
  /// transcript can show an edited command next to the text it replaced.
  List<AgentCommandApproval> approvalsFor(String toolCallId) =>
      _approvals[toolCallId] ?? const [];

  String toolLabel(String name) => _toolSet?.find(name)?.label ?? name;

  /// Loads settings and the most recent conversation for this host.
  Future<void> load() async {
    try {
      _provider = await _settings.loadDefaultProvider();
      _webSearch = await _settings.loadWebSearch();
      _workSpec = await _settings.loadWorkSpec();
      _sessionList = await _sessionStore.list(hostId: _host.id);
      final session = _sessionList.isEmpty ? null : _sessionList.first;
      _current = session;
      _messages.clear();
      if (session != null) {
        _messages.addAll(await _sessionStore.loadTranscript(session.id));
      }
      _error = null;
    } on AgentSettingsException catch (error) {
      _error = error.message;
    } on AgentSessionException catch (error) {
      _error = error.message;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Re-reads provider, Web Search and work-spec settings after the user edited
  /// them. The next run picks the new values up; a running loop is untouched.
  Future<void> reloadSettings() async {
    try {
      _provider = await _settings.loadDefaultProvider();
      _webSearch = await _settings.loadWebSearch();
      _workSpec = await _settings.loadWorkSpec();
      _error = null;
    } on AgentSettingsException catch (error) {
      _error = error.message;
    }
    _notify();
  }

  /// Sends a user message and runs the loop until it stops asking for tools.
  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || _running || _loading) return;
    final provider = _provider;
    if (provider == null) {
      _error = '还没有配置 Agent Provider，请先到设置里添加一个。';
      _notify();
      return;
    }
    final String apiKey;
    try {
      final stored = await _settings.readApiKey(provider);
      if (stored == null) {
        _error = 'Provider「${provider.name}」还没有 API Key，请到设置里补上。';
        _notify();
        return;
      }
      apiKey = stored;
    } on AgentSettingsException catch (error) {
      _error = error.message;
      _notify();
      return;
    }
    final session = await _ensureSession();
    if (session == null) return;
    _error = null;
    _messages.add(AgentUserMessage(text: prompt));
    _notify();
    await _startRun(provider, apiKey);
  }

  /// Stops the run: cancels the HTTP stream, every in-flight tool and any
  /// approval the user has not decided yet.
  void stop() {
    if (!_running) return;
    _completeApproval(
      AgentApprovalOutcome.cancelled(_pending?.id ?? ''),
      settle: true,
    );
    _loop?.cancel();
    _notify();
  }

  Future<void> _startRun(AgentProviderConfig provider, String apiKey) async {
    final toolSet = AgentToolSet(
      AgentToolContext(
        terminal: _terminal,
        files: _files,
        status: _serverStatus,
        history: _historyBridge,
        webSearch: AgentWebSearchRuntime(
          settings: _settings,
          config: _webSearch,
        ),
        approvals: this,
      ),
    );
    final loop = AgentLoop(
      provider: _providerFactory(provider.protocol),
      config: provider,
      apiKey: apiKey,
      systemPrompt: AgentSystemPrompt.build(
        session: _terminal.describeSession(),
        toolSet: toolSet,
        workSpec: _workSpec,
      ),
      toolSet: toolSet,
      limits: AgentLoopLimits(maxSteps: provider.maxLoops),
    );
    _toolSet = toolSet;
    _loop = loop;
    _running = true;
    _status = const AgentStatus(kind: AgentStatusKind.connecting);
    _notify();
    _subscription = loop
        .run(List.of(_messages))
        .listen(
          _onEvent,
          onError: (Object error, StackTrace _) {
            _error = '本轮运行异常终止：$error';
            _finishRun();
          },
          onDone: _finishRun,
        );
    await _persist();
  }

  void _onEvent(AgentRuntimeEvent event) {
    switch (event) {
      case AgentRunStarted():
        _status = const AgentStatus(kind: AgentStatusKind.connecting);
      case AgentTurnStarted():
        break;
      case AgentTextDelta():
      case AgentToolCallDelta():
        break;
      case AgentMessageUpdated(:final message):
        _streaming = message;
      case AgentMessageAppended(:final message):
        _streaming = null;
        _messages.add(message);
      case AgentStatusChanged(:final status):
        _status = status;
      case AgentToolStarted(:final toolCallId, :final toolName):
        _activeTool = AgentActiveTool(
          toolCallId: toolCallId,
          toolName: toolName,
          label: toolLabel(toolName),
        );
      case AgentToolFinished(:final result):
        _activeTool = null;
        _messages.add(result);
      case AgentUsageReported(:final total):
        _usage = total;
      case AgentRunCompleted(:final usage):
        _usage = usage;
        _finishRun();
        return;
      case AgentRunCancelled():
        _status = null;
        _finishRun();
        return;
      case AgentRunFailed(:final failure):
        _error = _describeFailure(failure);
        _finishRun();
        return;
    }
    _notify();
  }

  /// Keeps the redacted provider detail (status text, request URL) attached to
  /// the message so a misconfigured endpoint is diagnosable without a log.
  String _describeFailure(AgentFailure failure) {
    final detail = failure.detail;
    if (detail == null || detail.isEmpty) return failure.message;
    return '${failure.message}\n$detail';
  }

  void _finishRun() {
    if (_running) {
      _running = false;
      _status = null;
      _streaming = null;
      _activeTool = null;
      _loop = null;
      final subscription = _subscription;
      _subscription = null;
      unawaited(subscription?.cancel());
      _completeApproval(
        AgentApprovalOutcome.cancelled(_pending?.id ?? ''),
        settle: true,
      );
      unawaited(_persist());
    }
    _notify();
  }

  Future<void> _persist() async {
    final session = _current;
    if (session == null) return;
    try {
      await _sessionStore.saveTranscript(
        session.id,
        _messages,
        title: session.messageCount == 0 && _messages.isNotEmpty
            ? AgentSessionRepository.titleFromTranscript(_messages)
            : null,
      );
      await _refreshSessions();
    } on AgentSessionException catch (error) {
      _error = error.message;
      _notify();
    }
  }

  Future<void> _refreshSessions() async {
    _sessionList = await _sessionStore.list(hostId: _host.id);
    final id = _current?.id;
    if (id != null) _current = _summaryById(id) ?? _current;
    _notify();
  }

  Future<AgentSessionSummary?> _ensureSession() async {
    final existing = _current;
    if (existing != null) return existing;
    try {
      final created = await _sessionStore.create(hostId: _host.id);
      _current = created;
      await _refreshSessions();
      return _current;
    } on AgentSessionException catch (error) {
      _error = error.message;
      _notify();
      return null;
    }
  }

  /// Starts a fresh conversation. A session that is already empty is reused so
  /// repeated taps do not pile up blank sessions.
  Future<void> newSession() async {
    if (_running) return;
    if (_current != null && _messages.isEmpty) return;
    try {
      final created = await _sessionStore.create(hostId: _host.id);
      _resetTranscript();
      _current = created;
      await _refreshSessions();
    } on AgentSessionException catch (error) {
      _error = error.message;
    }
    _notify();
  }

  Future<void> switchSession(String id) async {
    if (_running || id == _current?.id) return;
    try {
      final transcript = await _sessionStore.loadTranscript(id);
      _resetTranscript();
      _current = _summaryById(id);
      _messages.addAll(transcript);
    } on AgentSessionException catch (error) {
      _error = error.message;
    }
    _notify();
  }

  Future<void> renameSession(String id, String title) async {
    try {
      await _sessionStore.rename(id, title);
      await _refreshSessions();
    } on AgentSessionException catch (error) {
      _error = error.message;
      _notify();
    }
  }

  Future<void> deleteSession(String id) async {
    if (_running) return;
    try {
      await _sessionStore.delete(id);
      if (_current?.id == id) {
        _resetTranscript();
        _current = null;
      }
      await _refreshSessions();
      final next = _sessionList.isEmpty ? null : _sessionList.first;
      if (_current == null && next != null) await switchSession(next.id);
    } on AgentSessionException catch (error) {
      _error = error.message;
    }
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void _resetTranscript() {
    _messages.clear();
    _approvals.clear();
    _streaming = null;
    _activeTool = null;
    _status = null;
    _usage = const AgentUsage();
    _error = null;
  }

  AgentSessionSummary? _summaryById(String id) {
    for (final summary in _sessionList) {
      if (summary.id == id) return summary;
    }
    return null;
  }

  // --- Approval boundary -----------------------------------------------------

  @override
  Future<AgentApprovalOutcome> requestApproval(AgentCommandApproval approval) {
    final loop = _loop;
    if (loop == null || loop.isCancelled) {
      return Future.value(AgentApprovalOutcome.cancelled(approval.id));
    }
    final completer = Completer<AgentApprovalOutcome>();
    _approvalCompleter = completer;
    _pending = approval;
    _recordApproval(approval);
    _notify();
    return completer.future;
  }

  @override
  void reportCommandPhase(
    String approvalId,
    String commandId,
    AgentCommandPhase phase,
  ) {
    final current = _pending;
    if (current == null || current.id != approvalId) return;
    final updated = current
        .withPhase(commandId, phase)
        .copyWith(executing: phase == AgentCommandPhase.running);
    _pending = updated;
    _recordApproval(updated);
    _notify();
  }

  @override
  void finishApproval(String approvalId) {
    final current = _pending;
    if (current == null || current.id != approvalId) return;
    _recordApproval(current.copyWith(settled: true, executing: false));
    _pending = null;
    _notify();
  }

  void approveCommand(String commandId) =>
      _decide(commandId, AgentCommandDecision.approved);

  void rejectCommand(String commandId) =>
      _decide(commandId, AgentCommandDecision.rejected);

  void approveAll() => _decideAll(AgentCommandDecision.approved);

  void rejectAll() => _decideAll(AgentCommandDecision.rejected);

  /// Rewrites one command. Per the approval rules this never mutates the record
  /// the user already saw: it publishes a replacement whose decisions are all
  /// pending again, so the edited text has to be approved on its own.
  void editCommand(String commandId, String command) {
    final current = _pending;
    if (current == null || current.executing) return;
    final text = command.trim();
    if (text.isEmpty) return;
    final replacement = current.replaceCommand(commandId, text);
    _pending = replacement;
    _recordApproval(replacement);
    _notify();
  }

  void _decide(String commandId, AgentCommandDecision decision) {
    final current = _pending;
    if (current == null || current.executing) return;
    _publishDecision(current.decide(commandId, decision));
  }

  void _decideAll(AgentCommandDecision decision) {
    final current = _pending;
    if (current == null || current.executing) return;
    _publishDecision(current.decideAll(decision));
  }

  void _publishDecision(AgentCommandApproval updated) {
    _pending = updated;
    _recordApproval(updated);
    if (updated.isDecided) {
      _completeApproval(
        AgentApprovalOutcome(
          approvalId: updated.id,
          commands: updated.commands,
          cancelled: false,
        ),
      );
    }
    _notify();
  }

  void _completeApproval(AgentApprovalOutcome outcome, {bool settle = false}) {
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(outcome);
    }
    if (!settle) return;
    final pending = _pending;
    if (pending == null) return;
    _recordApproval(pending.copyWith(settled: true, executing: false));
    _pending = null;
  }

  void _recordApproval(AgentCommandApproval approval) {
    final trail = _approvals.putIfAbsent(
      approval.toolCallId,
      () => <AgentCommandApproval>[],
    );
    final index = trail.indexWhere((item) => item.id == approval.id);
    if (index == -1) {
      trail.add(approval);
    } else {
      trail[index] = approval;
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loop?.cancel();
    _completeApproval(AgentApprovalOutcome.cancelled(_pending?.id ?? ''));
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_files.dispose());
    super.dispose();
  }

  static AgentProvider _defaultProviderFactory(
    AgentProviderProtocol protocol,
  ) => switch (protocol) {
    AgentProviderProtocol.messages => MessagesAgentProvider(),
    AgentProviderProtocol.responses => ResponsesAgentProvider(),
  };
}
