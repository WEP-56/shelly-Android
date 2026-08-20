import 'dart:async';

import '../../../core/ssh/ssh_session_controller.dart';
import '../../sftp/sftp_session.dart';
import '../domain/agent_failure.dart';
import '../domain/agent_runtime_bridges.dart';

/// Read-only remote filesystem access for the agent, over the app's own SFTP
/// session. Only list, stat and bounded text reads are wired up; the write,
/// rename and delete methods of [SftpSession] are deliberately not reachable
/// from here.
class AgentRemoteFileRuntime implements AgentRemoteFileBridge {
  AgentRemoteFileRuntime(this._session);

  final SshSessionController _session;

  SftpSession? _sftp;
  Future<SftpSession>? _opening;

  @override
  Future<List<AgentRemoteEntry>> listDirectory(String path) async {
    final sftp = await _ensureSession();
    try {
      final resolved = await sftp.resolvePath(path);
      final entries = await sftp.listDirectory(resolved);
      return [for (final entry in entries) _convert(entry)];
    } on SftpFailure catch (failure) {
      throw AgentToolException(failure.message);
    }
  }

  @override
  Future<AgentRemoteEntry> stat(String path) async {
    final sftp = await _ensureSession();
    try {
      final resolved = await sftp.resolvePath(path);
      return _convert(await sftp.stat(resolved));
    } on SftpFailure catch (failure) {
      throw AgentToolException(failure.message);
    }
  }

  @override
  Future<AgentRemoteTextFile> readText(
    String path, {
    required int maxBytes,
  }) async {
    final sftp = await _ensureSession();
    try {
      final resolved = await sftp.resolvePath(path);
      final entry = await sftp.stat(resolved);
      if (entry.type == RemoteEntryType.directory) {
        throw AgentToolException('$resolved 是目录，请改用 sftp_list。');
      }
      final size = entry.size;
      if (size != null && size > maxBytes) {
        throw AgentToolException(
          '文件 $size 字节，超过 Agent 单次读取上限 $maxBytes 字节。'
          '请改用 request_commands 申请 head/tail/grep 之类的命令，只取需要的部分。',
        );
      }
      final text = await sftp.readText(resolved, maxBytes: maxBytes);
      return AgentRemoteTextFile(path: resolved, text: text, sizeBytes: size);
    } on SftpFailure catch (failure) {
      throw AgentToolException(failure.message);
    }
  }

  /// Closes the SFTP channel opened for the agent, if any.
  Future<void> dispose() async {
    final sftp = _sftp;
    _sftp = null;
    _opening = null;
    if (sftp != null && !sftp.isClosed) await sftp.close();
  }

  Future<SftpSession> _ensureSession() async {
    final existing = _sftp;
    if (existing != null && !existing.isClosed) return existing;
    final pending = _opening;
    if (pending != null) return pending;
    final future = _openSession();
    _opening = future;
    try {
      final session = await future;
      _sftp = session;
      return session;
    } finally {
      _opening = null;
    }
  }

  Future<SftpSession> _openSession() async {
    if (!_session.isConnected) {
      throw const AgentToolException('SSH 会话未连接，无法使用 SFTP。');
    }
    try {
      return await _session.openSftpSession();
    } on SftpFailure catch (failure) {
      throw AgentToolException(failure.message);
    }
  }

  static AgentRemoteEntry _convert(RemoteFileEntry entry) {
    return AgentRemoteEntry(
      name: entry.name,
      path: entry.path,
      kind: switch (entry.type) {
        RemoteEntryType.file => 'file',
        RemoteEntryType.directory => 'directory',
        RemoteEntryType.symbolicLink => 'symlink',
        RemoteEntryType.other => 'other',
      },
      sizeBytes: entry.size,
      modifiedAt: entry.modifiedAt,
      permissions: entry.permissions,
    );
  }
}
