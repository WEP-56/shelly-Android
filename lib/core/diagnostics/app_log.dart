import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

/// A single diagnostic line.
class LogRecord {
  const LogRecord({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
  });

  final DateTime at;
  final LogLevel level;
  final String tag;
  final String message;

  /// Class name of the thrown object, never the object itself, so a record can
  /// be shown in the UI without risking that an exception carrying credentials
  /// leaks into a screenshot.
  final String? error;

  @override
  String toString() {
    final suffix = error == null ? '' : ' ($error)';
    return '[${level.name.toUpperCase()}] $tag: $message$suffix';
  }
}

/// Process-wide diagnostic sink.
///
/// Everything that used to go to a bare `debugPrint` goes here instead: the
/// record is kept in a bounded buffer so features can surface it (the terminal's
/// connection diagnostics does), and it is still printed in debug builds.
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const capacity = 200;

  final Queue<LogRecord> _records = Queue<LogRecord>();

  /// Oldest first.
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_records);

  void debug(String tag, String message, {Object? error}) =>
      log(LogLevel.debug, tag, message, error: error);

  void info(String tag, String message, {Object? error}) =>
      log(LogLevel.info, tag, message, error: error);

  void warning(String tag, String message, {Object? error}) =>
      log(LogLevel.warning, tag, message, error: error);

  void error(String tag, String message, {Object? error}) =>
      log(LogLevel.error, tag, message, error: error);

  void log(LogLevel level, String tag, String message, {Object? error}) {
    final record = LogRecord(
      at: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error == null ? null : describeError(error),
    );
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
    if (kDebugMode) {
      // Debug builds also get the exception itself, which never leaves the
      // developer's console.
      final detail = error == null ? '' : '\n  $error';
      debugPrint('$record$detail');
    }
  }

  void clear() => _records.clear();

  /// The class name of [error], with the message stripped.
  ///
  /// `SocketException` and friends render their payload in `toString()`, and an
  /// auth-related throwable could in principle render more, so only the type is
  /// ever retained for display.
  static String describeError(Object error) => error.runtimeType.toString();
}
