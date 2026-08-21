import 'dart:collection';

import '../diagnostics/app_log.dart';
import 'ssh_models.dart';

enum SshConnectionEventKind {
  /// A connection state transition.
  state,

  /// A liveness probe result worth remembering (a failure or a recovery).
  health,

  /// An auto-reconnect attempt, its delay, or its outcome.
  reconnect,

  /// Something recoverable that did not change the connection state.
  warning,

  /// The session moved to `failed`.
  failure,

  /// An SFTP channel was opened, reused, closed, or refused.
  channel,
}

/// One entry of the per-session connection log.
///
/// Deliberately carries no command text, no path, and no credential material:
/// the whole point is that the user can screenshot it and send it over.
class SshConnectionEvent {
  const SshConnectionEvent({
    required this.at,
    required this.kind,
    required this.message,
    this.state,
    this.stage,
    this.errorType,
  });

  final DateTime at;
  final SshConnectionEventKind kind;
  final String message;
  final SshConnectionState? state;
  final SshFailureStage? stage;

  /// Class name of the exception only — never its message.
  final String? errorType;
}

/// Bounded ring buffer of [SshConnectionEvent]s owned by one SSH session.
class SshConnectionEventLog {
  SshConnectionEventLog({this.capacity = 80});

  final int capacity;
  final Queue<SshConnectionEvent> _events = Queue<SshConnectionEvent>();

  /// Oldest first.
  List<SshConnectionEvent> get events =>
      List<SshConnectionEvent>.unmodifiable(_events);

  bool get isEmpty => _events.isEmpty;

  void add(
    SshConnectionEventKind kind,
    String message, {
    SshConnectionState? state,
    SshFailureStage? stage,
    Object? error,
  }) {
    _events.addLast(
      SshConnectionEvent(
        at: DateTime.now(),
        kind: kind,
        message: message,
        state: state,
        stage: stage,
        errorType: error == null ? null : AppLog.describeError(error),
      ),
    );
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  void clear() => _events.clear();
}
