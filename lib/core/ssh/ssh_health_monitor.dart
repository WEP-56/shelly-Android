import 'dart:async';

/// Application-level liveness checking for one SSH connection.
///
/// dartssh2's own `keepAliveInterval` cannot be used for detection: its
/// `SSHKeepAlive` swallows every exception, and `SSHClient.ping()` waits for the
/// reply without a timeout, so after a single unanswered ping it stops pinging
/// and never reports anything. This monitor drives the same ping but with a
/// timeout, counts consecutive failures, and only then declares the link lost.
///
/// It also doubles as the heartbeat: each probe is a real
/// `keepalive@openssh.com` global request, which is what keeps NAT entries and
/// the server's `ClientAliveInterval` happy.
class SshHealthMonitor {
  SshHealthMonitor({
    required Future<void> Function() probe,
    required void Function(Object error, int consecutiveFailures) onProbeFailed,
    required void Function(int recoveredAfterFailures) onProbeRecovered,
    required void Function(Object error, bool immediate) onLinkLost,
    this.interval = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 10),
    this.maxFailures = 3,
    this.immediateMaxFailures = 2,
    this.immediateRetryDelay = const Duration(seconds: 3),
  }) : _probe = probe,
       _onProbeFailed = onProbeFailed,
       _onProbeRecovered = onProbeRecovered,
       _onLinkLost = onLinkLost;

  final Future<void> Function() _probe;
  final void Function(Object error, int consecutiveFailures) _onProbeFailed;
  final void Function(int recoveredAfterFailures) _onProbeRecovered;
  final void Function(Object error, bool immediate) _onLinkLost;

  /// How often the heartbeat probe runs while the session is connected.
  final Duration interval;

  /// How long a single probe may take before it counts as failed.
  final Duration timeout;

  /// Consecutive probe failures tolerated before the link is declared lost.
  final int maxFailures;

  /// Lower threshold for checks triggered by resume/visibility, where the app
  /// has good reason to suspect the link died while it was not looking.
  final int immediateMaxFailures;

  /// Gap before the follow-up probe of an immediate check.
  final Duration immediateRetryDelay;

  Timer? _timer;
  Timer? _followUpTimer;
  bool _checking = false;
  bool _pendingImmediate = false;
  int _failures = 0;
  int _epoch = 0;
  bool _disposed = false;

  bool get isRunning => _timer != null;
  int get consecutiveFailures => _failures;

  /// Arms the periodic heartbeat. Safe to call repeatedly.
  void start() {
    if (_disposed || _timer != null) return;
    _failures = 0;
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  /// Disarms the heartbeat and invalidates any probe still in flight.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _followUpTimer?.cancel();
    _followUpTimer = null;
    _pendingImmediate = false;
    _failures = 0;
    // In-flight probes belong to the previous epoch and are ignored on return.
    ++_epoch;
    _checking = false;
  }

  /// Runs one probe.
  ///
  /// [immediate] marks a check triggered by something that makes a dead link
  /// likely — coming back to the foreground, or the file drawer closing — and
  /// lowers the failure threshold accordingly.
  ///
  /// Overlapping calls never stack: a check requested while one is in flight is
  /// remembered and, if it was an immediate one, replayed once the current probe
  /// settles.
  Future<void> check({bool immediate = false}) async {
    if (_disposed) return;
    if (_checking) {
      _pendingImmediate = _pendingImmediate || immediate;
      return;
    }
    _checking = true;
    final epoch = _epoch;
    try {
      await _probe().timeout(timeout);
      if (_disposed || epoch != _epoch) return;
      final recoveredAfter = _failures;
      _failures = 0;
      if (recoveredAfter > 0) _onProbeRecovered(recoveredAfter);
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      ++_failures;
      _onProbeFailed(error, _failures);
      final threshold = immediate ? immediateMaxFailures : maxFailures;
      if (_failures >= threshold) {
        stop();
        _onLinkLost(error, immediate);
        return;
      }
      if (immediate) _scheduleFollowUp();
    } finally {
      if (epoch == _epoch) _checking = false;
    }
    if (_disposed || epoch != _epoch) return;
    if (_pendingImmediate) {
      _pendingImmediate = false;
      await check(immediate: true);
    }
  }

  void _scheduleFollowUp() {
    _followUpTimer?.cancel();
    _followUpTimer = Timer(
      immediateRetryDelay,
      () => unawaited(check(immediate: true)),
    );
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
