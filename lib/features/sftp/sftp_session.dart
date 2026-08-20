import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path;

enum RemoteEntryType { file, directory, symbolicLink, other }

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.type,
    required this.size,
    required this.modifiedAt,
    required this.permissions,
  });

  final String name;
  final String path;
  final RemoteEntryType type;
  final int? size;
  final DateTime? modifiedAt;
  final String? permissions;

  bool get isDirectory => type == RemoteEntryType.directory;
  bool get isFile => type == RemoteEntryType.file;
}

class SftpFailure implements Exception {
  const SftpFailure(this.message, {required this.path, this.cause});

  final String message;
  final String path;
  final Object? cause;

  @override
  String toString() => message;
}

class SftpTransferCancelled implements Exception {
  const SftpTransferCancelled();
}

class SftpTransferControl {
  bool _cancelled = false;
  bool _paused = false;
  Completer<void>? _resumeCompleter;

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused;

  void pause() {
    if (_cancelled || _paused) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    resume();
  }

  Future<void> waitUntilRunnable() async {
    if (_cancelled) throw const SftpTransferCancelled();
    final resume = _resumeCompleter;
    if (_paused && resume != null) await resume.future;
    if (_cancelled) throw const SftpTransferCancelled();
  }
}

class SftpSession {
  SftpSession(this._client, {void Function()? onClosed}) : _onClosed = onClosed;

  final SftpClient _client;
  final void Function()? _onClosed;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<String> resolvePath(String remotePath) =>
      _guard(remotePath, () => _client.absolute(remotePath));

  Future<List<RemoteFileEntry>> listDirectory(String remotePath) async {
    return _guard(remotePath, () async {
      final names = await _client.listdir(remotePath);
      final entries = <RemoteFileEntry>[];
      for (final item in names) {
        if (item.filename == '.' || item.filename == '..') continue;
        entries.add(_entryFromName(remotePath, item));
      }
      return entries;
    });
  }

  Future<RemoteFileEntry> stat(String remotePath) async {
    return _guard(remotePath, () async {
      final attrs = await _client.stat(remotePath, followLink: false);
      return _entryFromAttrs(remotePath, attrs);
    });
  }

  Future<String> readText(String remotePath, {int maxBytes = 256 * 1024}) {
    return _guard(remotePath, () async {
      final attrs = await _client.stat(remotePath);
      final size = attrs.size;
      if (size != null && size > maxBytes) {
        throw SftpFailure('文件超过预览上限（256 KB）。', path: remotePath);
      }
      final file = await _client.open(remotePath);
      try {
        final bytes = await file.readBytes(length: size);
        if (bytes.contains(0)) {
          throw SftpFailure('该文件可能是二进制文件，无法文本预览。', path: remotePath);
        }
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await file.close();
      }
    });
  }

  Future<void> createDirectory(String remotePath) =>
      _guard(remotePath, () => _client.mkdir(remotePath));

  Future<void> rename(String oldPath, String newPath) =>
      _guard(oldPath, () => _client.rename(oldPath, newPath));

  Future<void> delete(RemoteFileEntry entry, {required bool recursive}) {
    return _guard(entry.path, () async {
      if (!entry.isDirectory) {
        await _client.remove(entry.path);
        return;
      }
      if (recursive) await _deleteDirectoryContents(entry.path);
      await _client.rmdir(entry.path);
    });
  }

  Future<void> download({
    required String remotePath,
    required String localPath,
    required SftpTransferControl control,
    required void Function(int transferred, int? total) onProgress,
  }) async {
    final destination = File(localPath);
    final temporary = File(
      '$localPath.shelly-download-${DateTime.now().microsecondsSinceEpoch}',
    );
    IOSink? sink;
    try {
      final attrs = await _client.stat(remotePath);
      final file = await _client.open(remotePath);
      try {
        sink = temporary.openWrite(mode: FileMode.writeOnly);
        var transferred = 0;
        await for (final chunk in file.read(length: attrs.size)) {
          await control.waitUntilRunnable();
          sink.add(chunk);
          transferred += chunk.length;
          onProgress(transferred, attrs.size);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (await destination.exists()) await destination.delete();
        await temporary.rename(localPath);
      } finally {
        await file.close();
      }
    } on SftpTransferCancelled {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } on Object catch (error) {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      throw _failure('下载失败，请检查远程文件和本地存储权限。', remotePath, error);
    }
  }

  Future<void> upload({
    required String localPath,
    required String remotePath,
    required SftpTransferControl control,
    required void Function(int transferred, int total) onProgress,
  }) async {
    SftpFile? remoteFile;
    final temporaryPath =
        '$remotePath.shelly-upload-${DateTime.now().microsecondsSinceEpoch}';
    var completed = false;
    try {
      final source = File(localPath);
      final total = await source.length();
      remoteFile = await _client.open(
        temporaryPath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      var transferred = 0;
      await for (final chunk in source.openRead()) {
        await control.waitUntilRunnable();
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await remoteFile.writeBytes(bytes, offset: transferred);
        transferred += bytes.length;
        onProgress(transferred, total);
      }
      await remoteFile.close();
      remoteFile = null;
      await _client.rename(temporaryPath, remotePath);
      completed = true;
    } on SftpTransferCancelled {
      await remoteFile?.close();
      try {
        await _client.remove(temporaryPath);
      } on Object {
        // The partial file may already be absent after a connection loss.
      }
      rethrow;
    } on Object catch (error) {
      throw _failure('上传失败，请检查远程目录权限和可用空间。', remotePath, error);
    } finally {
      await remoteFile?.close();
      if (!completed) {
        try {
          await _client.remove(temporaryPath);
        } on Object {
          // Cleanup is best-effort after a connection failure.
        }
      }
    }
  }

  Future<void> _deleteDirectoryContents(String remotePath) async {
    final children = await _client.listdir(remotePath);
    for (final child in children) {
      if (child.filename == '.' || child.filename == '..') continue;
      final childPath = joinRemotePath(remotePath, child.filename);
      if (child.attr.isDirectory) {
        await _deleteDirectoryContents(childPath);
        await _client.rmdir(childPath);
      } else {
        await _client.remove(childPath);
      }
    }
  }

  RemoteFileEntry _entryFromName(String parent, SftpName item) {
    final remotePath = joinRemotePath(parent, item.filename);
    return _entryFromAttrs(remotePath, item.attr, name: item.filename);
  }

  RemoteFileEntry _entryFromAttrs(
    String remotePath,
    SftpFileAttrs attrs, {
    String? name,
  }) {
    final type = attrs.isDirectory
        ? RemoteEntryType.directory
        : attrs.isFile
        ? RemoteEntryType.file
        : attrs.isSymbolicLink
        ? RemoteEntryType.symbolicLink
        : RemoteEntryType.other;
    return RemoteFileEntry(
      name: name ?? path.posix.basename(remotePath),
      path: remotePath,
      type: type,
      size: attrs.size,
      modifiedAt: attrs.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              attrs.modifyTime! * 1000,
              isUtc: true,
            ),
      permissions: attrs.mode?.toString(),
    );
  }

  Future<T> _guard<T>(String remotePath, Future<T> Function() operation) async {
    if (_closed) {
      throw SftpFailure('SFTP 会话已经关闭。', path: remotePath);
    }
    try {
      return await operation();
    } on SftpFailure {
      rethrow;
    } on Object catch (error) {
      throw _failure('远程文件操作失败，请检查路径和权限。', remotePath, error);
    }
  }

  SftpFailure _failure(String message, String remotePath, Object error) {
    if (error is SftpFailure) return error;
    return SftpFailure(message, path: remotePath, cause: error);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _client.close();
    } finally {
      _onClosed?.call();
    }
  }
}

String joinRemotePath(String parent, String name) =>
    path.posix.normalize(path.posix.join(parent, name));

String parentRemotePath(String remotePath) {
  final normalized = path.posix.normalize(remotePath);
  if (normalized == '/') return '/';
  return path.posix.dirname(normalized);
}
