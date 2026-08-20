import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../core/ssh/ssh_session_controller.dart';
import 'sftp_session.dart';

enum SftpTransferDirection { upload, download }

enum SftpTransferStatus {
  queued,
  running,
  paused,
  completed,
  failed,
  cancelled,
}

class SftpTransferTask {
  const SftpTransferTask({
    required this.id,
    required this.direction,
    required this.localPath,
    required this.remotePath,
    required this.status,
    required this.transferredBytes,
    required this.totalBytes,
    required this.errorMessage,
    required this.bytesPerSecond,
  });

  final String id;
  final SftpTransferDirection direction;
  final String localPath;
  final String remotePath;
  final SftpTransferStatus status;
  final int transferredBytes;
  final int? totalBytes;
  final String? errorMessage;
  final double? bytesPerSecond;

  String get name => direction == SftpTransferDirection.upload
      ? path.basename(localPath)
      : path.posix.basename(remotePath);

  double? get progress {
    final total = totalBytes;
    if (total == null || total == 0) return null;
    return (transferredBytes / total).clamp(0, 1);
  }

  SftpTransferTask copyWith({
    SftpTransferStatus? status,
    int? transferredBytes,
    int? totalBytes,
    String? errorMessage,
    bool clearError = false,
    double? bytesPerSecond,
    bool clearSpeed = false,
    bool clearTotal = false,
  }) {
    return SftpTransferTask(
      id: id,
      direction: direction,
      localPath: localPath,
      remotePath: remotePath,
      status: status ?? this.status,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: clearTotal ? null : totalBytes ?? this.totalBytes,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      bytesPerSecond: clearSpeed ? null : bytesPerSecond ?? this.bytesPerSecond,
    );
  }
}

class SftpTransferController extends ChangeNotifier {
  SftpTransferController({
    required SshSessionController sshSession,
    this.maxConcurrent = 2,
    Uuid? uuid,
  }) : _sshSession = sshSession,
       _uuid = uuid ?? const Uuid();

  final SshSessionController _sshSession;
  final int maxConcurrent;
  final Uuid _uuid;
  final List<SftpTransferTask> _tasks = [];
  final Map<String, SftpTransferControl> _controls = {};
  final Map<String, Stopwatch> _stopwatches = {};
  int _running = 0;
  bool _disposed = false;

  List<SftpTransferTask> get tasks => List.unmodifiable(_tasks.reversed);
  bool get hasActiveTransfers => _tasks.any(
    (task) =>
        task.status == SftpTransferStatus.queued ||
        task.status == SftpTransferStatus.running ||
        task.status == SftpTransferStatus.paused,
  );

  void enqueueUpload({required String localPath, required String remotePath}) {
    _enqueue(SftpTransferDirection.upload, localPath, remotePath);
  }

  void enqueueDownload({
    required String remotePath,
    required String localPath,
  }) {
    _enqueue(SftpTransferDirection.download, localPath, remotePath);
  }

  void _enqueue(
    SftpTransferDirection direction,
    String localPath,
    String remotePath,
  ) {
    _tasks.add(
      SftpTransferTask(
        id: _uuid.v4(),
        direction: direction,
        localPath: localPath,
        remotePath: remotePath,
        status: SftpTransferStatus.queued,
        transferredBytes: 0,
        totalBytes: null,
        errorMessage: null,
        bytesPerSecond: null,
      ),
    );
    _notify();
    _drainQueue();
  }

  void pause(String id) {
    final task = _find(id);
    if (task == null || task.status != SftpTransferStatus.running) return;
    _controls[id]?.pause();
    _replace(task.copyWith(status: SftpTransferStatus.paused));
  }

  void resume(String id) {
    final task = _find(id);
    if (task == null || task.status != SftpTransferStatus.paused) return;
    _controls[id]?.resume();
    _replace(task.copyWith(status: SftpTransferStatus.running));
  }

  void cancel(String id) {
    final task = _find(id);
    if (task == null ||
        task.status == SftpTransferStatus.completed ||
        task.status == SftpTransferStatus.cancelled) {
      return;
    }
    _controls[id]?.cancel();
    _replace(task.copyWith(status: SftpTransferStatus.cancelled));
    _drainQueue();
  }

  void retry(String id) {
    final task = _find(id);
    if (task == null ||
        (task.status != SftpTransferStatus.failed &&
            task.status != SftpTransferStatus.cancelled)) {
      return;
    }
    _replace(
      task.copyWith(
        status: SftpTransferStatus.queued,
        transferredBytes: 0,
        clearError: true,
        clearSpeed: true,
        clearTotal: true,
      ),
    );
    _drainQueue();
  }

  void removeFinished(String id) {
    _tasks.removeWhere(
      (task) =>
          task.id == id &&
          task.status != SftpTransferStatus.running &&
          task.status != SftpTransferStatus.paused &&
          task.status != SftpTransferStatus.queued,
    );
    _notify();
  }

  void _drainQueue() {
    if (_disposed) return;
    while (_running < maxConcurrent) {
      final queued = _tasks.where(
        (task) => task.status == SftpTransferStatus.queued,
      );
      if (queued.isEmpty) return;
      final task = queued.first;
      _running++;
      unawaited(_run(task));
    }
  }

  Future<void> _run(SftpTransferTask initialTask) async {
    final control = SftpTransferControl();
    _controls[initialTask.id] = control;
    _stopwatches[initialTask.id] = Stopwatch()..start();
    _replace(
      initialTask.copyWith(
        status: SftpTransferStatus.running,
        clearError: true,
      ),
    );
    SftpSession? session;
    try {
      session = await _sshSession.openSftpSession();
      final latest = _find(initialTask.id);
      if (latest?.status == SftpTransferStatus.cancelled) {
        throw const SftpTransferCancelled();
      }
      if (initialTask.direction == SftpTransferDirection.upload) {
        await session.upload(
          localPath: initialTask.localPath,
          remotePath: initialTask.remotePath,
          control: control,
          onProgress: (transferred, total) {
            _updateProgress(initialTask.id, transferred, total);
          },
        );
      } else {
        await session.download(
          remotePath: initialTask.remotePath,
          localPath: initialTask.localPath,
          control: control,
          onProgress: (transferred, total) {
            _updateProgress(initialTask.id, transferred, total);
          },
        );
      }
      final current = _find(initialTask.id);
      if (current?.status != SftpTransferStatus.cancelled) {
        _replace(current!.copyWith(status: SftpTransferStatus.completed));
      }
    } on SftpTransferCancelled {
      final current = _find(initialTask.id);
      if (current != null) {
        _replace(current.copyWith(status: SftpTransferStatus.cancelled));
      }
    } on SftpFailure catch (error) {
      final current = _find(initialTask.id);
      if (current != null && current.status != SftpTransferStatus.cancelled) {
        _replace(
          current.copyWith(
            status: SftpTransferStatus.failed,
            errorMessage: error.message,
          ),
        );
      }
    } finally {
      _controls.remove(initialTask.id);
      _stopwatches.remove(initialTask.id);
      await session?.close();
      _running--;
      _drainQueue();
    }
  }

  void _updateProgress(String id, int transferred, int? total) {
    final task = _find(id);
    if (task == null || task.status == SftpTransferStatus.cancelled) return;
    final elapsedMs = _stopwatches[id]?.elapsedMilliseconds ?? 0;
    final speed = elapsedMs <= 0 ? null : transferred * 1000 / elapsedMs;
    _replace(
      task.copyWith(
        transferredBytes: transferred,
        totalBytes: total,
        bytesPerSecond: speed,
      ),
    );
  }

  SftpTransferTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _replace(SftpTransferTask task) {
    final index = _tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) return;
    _tasks[index] = task;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final control in _controls.values) {
      control.cancel();
    }
    super.dispose();
  }
}
