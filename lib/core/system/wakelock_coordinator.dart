import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

import '../diagnostics/app_log.dart';

/// Reference-counted screen wakelock.
///
/// Two independent settings can want the screen awake — the global one and the
/// per-terminal one — so ownership is tracked by holder token: the lock is
/// released only once every holder has let go. Without this, closing a terminal
/// page would clear a wakelock the global setting still wants.
class WakelockCoordinator {
  WakelockCoordinator._();

  static final WakelockCoordinator instance = WakelockCoordinator._();

  static const _logTag = 'wakelock';

  final Set<Object> _holders = {};
  bool _desired = false;
  bool _applied = false;
  bool _applying = false;

  bool get isHeld => _desired;

  /// Registers [holder] as wanting the screen awake. Idempotent per holder.
  void hold(Object holder) {
    if (_holders.add(holder)) _sync();
  }

  void release(Object holder) {
    if (_holders.remove(holder)) _sync();
  }

  /// Convenience for a setting-driven holder.
  void setHeld(Object holder, bool held) {
    if (held) {
      hold(holder);
    } else {
      release(holder);
    }
  }

  void _sync() {
    final desired = _holders.isNotEmpty;
    if (desired == _desired) return;
    _desired = desired;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_applying) return;
    _applying = true;
    try {
      while (_applied != _desired) {
        final target = _desired;
        try {
          if (target) {
            await WakelockPlus.enable();
          } else {
            await WakelockPlus.disable();
          }
          _applied = target;
        } on Object catch (error) {
          // Platform refused (or the plugin is unavailable). Report it and stop
          // instead of spinning; the next change tries again.
          AppLog.instance.warning(
            _logTag,
            'failed to ${target ? 'enable' : 'disable'} the screen wakelock',
            error: error,
          );
          return;
        }
      }
    } finally {
      _applying = false;
    }
  }
}
