import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/ssh/ssh_connection_factory.dart';
import '../../core/ssh/ssh_session_controller.dart';

class ServerStatusCancelled implements Exception {
  const ServerStatusCancelled();
}

class ServerStatusException implements Exception {
  const ServerStatusException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class ServerStatusCancellationToken {
  SshCommandHandle? _command;
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void attach(SshCommandHandle command) {
    _command = command;
    if (_cancelled) command.close();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
    _command?.close();
  }
}

class ServerStatusSnapshot {
  const ServerStatusSnapshot({
    required this.hostname,
    required this.system,
    required this.cpu,
    required this.memory,
    required this.disk,
    required this.loadAverage,
    required this.uptime,
    required this.capturedAt,
  });

  final String? hostname;
  final String? system;
  final ServerStatusCpu cpu;
  final ServerStatusMemory memory;
  final ServerStatusDisk disk;
  final List<double> loadAverage;
  final Duration? uptime;
  final DateTime capturedAt;
}

class ServerStatusCpu {
  const ServerStatusCpu({this.model, this.cores, this.usage});

  final String? model;
  final int? cores;
  final double? usage;
}

class ServerStatusMemory {
  const ServerStatusMemory({this.totalBytes, this.availableBytes});

  final int? totalBytes;
  final int? availableBytes;

  double? get usage {
    final total = totalBytes;
    final available = availableBytes;
    if (total == null || available == null || total <= 0) return null;
    return ((total - available) / total).clamp(0, 1).toDouble();
  }
}

class ServerStatusDisk {
  const ServerStatusDisk({this.totalBytes, this.usedBytes});

  final int? totalBytes;
  final int? usedBytes;

  double? get usage {
    final total = totalBytes;
    final used = usedBytes;
    if (total == null || used == null || total <= 0) return null;
    return (used / total).clamp(0, 1).toDouble();
  }
}

class ServerStatusService {
  ServerStatusService(this._session);

  static const timeout = Duration(seconds: 12);
  static const _command = r'''printf '__SHELLY_HOST__\n';
hostname 2>/dev/null || uname -n 2>/dev/null;
printf '__SHELLY_UNAME__\n';
uname -srm 2>/dev/null;
printf '__SHELLY_OS__\n';
cat /etc/os-release 2>/dev/null;
printf '__SHELLY_CPU__\n';
sed -n '1,80p' /proc/cpuinfo 2>/dev/null;
printf '__SHELLY_CPU_CORES__\n';
getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null;
printf '__SHELLY_CPU_STAT_1__\n';
head -n 1 /proc/stat 2>/dev/null;
sleep 0.25;
printf '__SHELLY_CPU_STAT_2__\n';
head -n 1 /proc/stat 2>/dev/null;
printf '__SHELLY_MEM__\n';
cat /proc/meminfo 2>/dev/null;
printf '__SHELLY_DISK__\n';
df -Pk / 2>/dev/null;
printf '__SHELLY_LOAD__\n';
cat /proc/loadavg 2>/dev/null;
printf '__SHELLY_UPTIME__\n';
cat /proc/uptime 2>/dev/null;
''';

  final SshSessionController _session;

  Future<ServerStatusSnapshot> fetch({
    ServerStatusCancellationToken? cancellationToken,
    Duration requestTimeout = timeout,
  }) async {
    final token = cancellationToken ?? ServerStatusCancellationToken();
    if (!_session.isConnected) {
      throw const ServerStatusException('SSH 会话尚未连接。');
    }
    SshCommandHandle? command;
    final stopwatch = Stopwatch()..start();
    try {
      command = await _openCommand(token, requestTimeout);
      token.attach(command);
      final stdoutFuture = _read(command.stdout, token);
      final stderrFuture = _drain(command.stderr);
      final remaining = requestTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Status timeout');
      final results = await Future.wait<Object?>([
        command.done.then<Object?>((_) => null),
        stdoutFuture,
        stderrFuture.then<Object?>((_) => null),
      ]).timeout(remaining);
      if (token.isCancelled) throw const ServerStatusCancelled();
      if (!_session.isConnected) {
        throw const ServerStatusException('SSH 会话已经断开。');
      }
      return _parse(results[1]! as String);
    } on ServerStatusCancelled {
      rethrow;
    } on TimeoutException catch (error) {
      command?.close();
      throw ServerStatusException('读取服务器状态超时，请重试。', cause: error);
    } on ServerStatusException {
      rethrow;
    } on Object catch (error) {
      command?.close();
      if (token.isCancelled) throw const ServerStatusCancelled();
      throw ServerStatusException('读取服务器状态失败，请重试。', cause: error);
    } finally {
      command?.close();
    }
  }

  Future<SshCommandHandle> _openCommand(
    ServerStatusCancellationToken token,
    Duration requestTimeout,
  ) async {
    final commandFuture = _session.executeCommand(_command);
    try {
      return await Future.any<SshCommandHandle>([
        commandFuture,
        token.whenCancelled.then<SshCommandHandle>(
          (_) => throw const ServerStatusCancelled(),
        ),
      ]).timeout(requestTimeout);
    } on Object {
      unawaited(
        commandFuture.then<void>(
          (command) => command.close(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      rethrow;
    }
  }

  Future<String> _read(
    Stream<Uint8List> stream,
    ServerStatusCancellationToken token,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (token.isCancelled) throw const ServerStatusCancelled();
      if (builder.length + chunk.length > 128 * 1024) break;
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> _drain(Stream<Uint8List> stream) async {
    await for (final _ in stream) {}
  }

  ServerStatusSnapshot _parse(String output) {
    final sections = <String, String>{};
    String? current;
    final lines = output.split('\n');
    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.startsWith('__SHELLY_') && line.endsWith('__')) {
        if (current != null) sections[current] = buffer.toString().trim();
        current = line.substring(9, line.length - 2);
        buffer.clear();
      } else if (current != null) {
        buffer.writeln(line);
      }
    }
    if (current != null) sections[current] = buffer.toString().trim();
    if (sections.isEmpty) {
      throw const FormatException('Missing status sections');
    }

    final cpuInfo = sections['CPU'] ?? '';
    final model = _firstMatch(cpuInfo, [
      RegExp(
        r'^(?:model name|model|Hardware|Processor)\s*:\s*(.+)$',
        multiLine: true,
        caseSensitive: false,
      ),
    ]);
    final coreMatches = RegExp(
      r'^processor\s*:',
      multiLine: true,
    ).allMatches(cpuInfo).length;
    final cores =
        int.tryParse(_line(sections['CPU_CORES']) ?? '') ??
        (coreMatches == 0 ? null : coreMatches);
    final stat1 = _cpuStat(sections['CPU_STAT_1']);
    final stat2 = _cpuStat(sections['CPU_STAT_2']);
    final usage = stat1 == null || stat2 == null
        ? null
        : _cpuUsage(stat1, stat2);

    final mem = _keyedBytes(sections['MEM'] ?? '', 'MemTotal');
    final memoryText = sections['MEM'] ?? '';
    final available =
        _keyedBytes(memoryText, 'MemAvailable') ??
        _legacyAvailableMemory(memoryText);
    final disk = _disk(sections['DISK']);
    final os = _firstMatch(sections['OS'] ?? '', [
      RegExp(r'^PRETTY_NAME=(?:"([^"]+)"|(.+))$', multiLine: true),
      RegExp(r'^NAME=(?:"([^"]+)"|(.+))$', multiLine: true),
    ]);

    return ServerStatusSnapshot(
      hostname: _line(sections['HOST']),
      system: [
        os,
        _line(sections['UNAME']),
      ].whereType<String>().join(' · ').nullIfEmpty,
      cpu: ServerStatusCpu(model: model, cores: cores, usage: usage),
      memory: ServerStatusMemory(totalBytes: mem, availableBytes: available),
      disk: ServerStatusDisk(totalBytes: disk?.$1, usedBytes: disk?.$2),
      loadAverage: _loads(sections['LOAD']),
      uptime: _uptime(sections['UPTIME']),
      capturedAt: DateTime.now(),
    );
  }

  String? _line(String? value) {
    final line = value?.split('\n').first.trim();
    return line == null || line.isEmpty ? null : line;
  }

  String? _firstMatch(String value, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      if (match != null) return (match.group(1) ?? match.group(2))?.trim();
    }
    return null;
  }

  int? _keyedBytes(String value, String key) {
    final match = RegExp(
      '^${RegExp.escape(key)}\\s*:\\s*(\\d+)\\s*kB',
      multiLine: true,
    ).firstMatch(value);
    final kb = int.tryParse(match?.group(1) ?? '');
    return kb == null ? null : kb * 1024;
  }

  int? _legacyAvailableMemory(String value) {
    final parts = [
      _keyedBytes(value, 'MemFree'),
      _keyedBytes(value, 'Buffers'),
      _keyedBytes(value, 'Cached'),
    ];
    if (parts.every((value) => value == null)) return null;
    return parts.whereType<int>().fold<int>(0, (total, value) => total + value);
  }

  (int, int)? _disk(String? value) {
    final lines = value?.split('\n') ?? const <String>[];
    for (final line in lines.reversed) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 5 && int.tryParse(fields[1]) != null) {
        final total = int.tryParse(fields[1]);
        final used = int.tryParse(fields[2]);
        if (total != null && used != null) return (total * 1024, used * 1024);
      }
    }
    return null;
  }

  List<double> _loads(String? value) {
    final fields = value?.trim().split(RegExp(r'\s+')) ?? const <String>[];
    return fields
        .take(3)
        .map(double.tryParse)
        .whereType<double>()
        .toList(growable: false);
  }

  Duration? _uptime(String? value) {
    final seconds = double.tryParse(value?.split(RegExp(r'\s+')).first ?? '');
    return seconds == null
        ? null
        : Duration(milliseconds: (seconds * 1000).round());
  }

  (int, int, int)? _cpuStat(String? value) {
    final fields = value?.trim().split(RegExp(r'\s+')) ?? const <String>[];
    if (fields.length < 5 || fields.first != 'cpu') return null;
    final numbers = fields.skip(1).map(int.tryParse).toList();
    if (numbers.take(4).any((value) => value == null)) return null;
    final idle = numbers[3]! + (numbers.length > 4 ? (numbers[4] ?? 0) : 0);
    final total = numbers
        .take(8)
        .whereType<int>()
        .fold<int>(0, (a, b) => a + b);
    return (total, idle, numbers[0]!);
  }

  double? _cpuUsage((int, int, int) first, (int, int, int) second) {
    final total = second.$1 - first.$1;
    final idle = second.$2 - first.$2;
    return total <= 0 ? null : (1 - idle / total).clamp(0, 1).toDouble();
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
