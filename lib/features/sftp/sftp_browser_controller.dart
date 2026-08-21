import 'package:flutter/foundation.dart';

import '../../core/ssh/ssh_session_controller.dart';
import 'sftp_session.dart';

enum SftpBrowserStatus { loading, ready, failure }

enum RemoteFileSort { name, modified, size }

class SftpBrowserController extends ChangeNotifier {
  SftpBrowserController({
    required SshSessionController sshSession,
    this.initialPath,
  }) : _sshSession = sshSession;

  final SshSessionController _sshSession;
  final String? initialPath;
  SftpSession? _sftp;
  SftpBrowserStatus _status = SftpBrowserStatus.loading;
  List<RemoteFileEntry> _entries = const [];
  String _path = '.';
  String _query = '';
  String? _errorMessage;
  RemoteFileSort _sort = RemoteFileSort.name;
  bool _ascending = true;
  bool _mutating = false;
  bool _disposed = false;
  int _loadRevision = 0;

  SftpBrowserStatus get status => _status;
  String get path => _path;
  String? get errorMessage => _errorMessage;
  RemoteFileSort get sort => _sort;
  bool get ascending => _ascending;
  bool get mutating => _mutating;

  List<RemoteFileEntry> get visibleEntries {
    final normalizedQuery = _query.toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? List<RemoteFileEntry>.of(_entries)
        : _entries
              .where(
                (entry) => entry.name.toLowerCase().contains(normalizedQuery),
              )
              .toList();
    filtered.sort(_compareEntries);
    return filtered;
  }

  int get loadedCount => _entries.length;

  Future<void> load([String? requestedPath]) async {
    final revision = ++_loadRevision;
    _status = SftpBrowserStatus.loading;
    _errorMessage = null;
    _notify();
    try {
      final sftp = await _ensureSftp();
      if (revision != _loadRevision || _disposed) return;
      final target =
          requestedPath ?? (_path == '.' ? initialPath ?? '.' : _path);
      final resolved = await sftp.resolvePath(target);
      final entries = await sftp.listDirectory(resolved);
      if (revision != _loadRevision || _disposed) return;
      _path = resolved;
      _entries = entries;
      _status = SftpBrowserStatus.ready;
    } on SftpFailure catch (error) {
      if (revision != _loadRevision || _disposed) return;
      _errorMessage = error.message;
      _status = SftpBrowserStatus.failure;
    }
    _notify();
  }

  Future<void> openDirectory(RemoteFileEntry entry) {
    if (!entry.isDirectory) return Future.value();
    return load(entry.path);
  }

  Future<void> goUp() => load(parentRemotePath(_path));

  void search(String value) {
    _query = value.trim();
    _notify();
  }

  void setSort(RemoteFileSort value) {
    if (_sort == value) {
      _ascending = !_ascending;
    } else {
      _sort = value;
      _ascending = true;
    }
    _notify();
  }

  Future<String> preview(RemoteFileEntry entry) async {
    final sftp = _requireSftp();
    return sftp.readText(entry.path);
  }

  Future<RemoteFileEntry> stat(RemoteFileEntry entry) {
    return _requireSftp().stat(entry.path);
  }

  Future<void> createDirectory(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.contains('/')) {
      throw SftpFailure('目录名称无效。', path: _path);
    }
    await _mutate(
      () => _requireSftp().createDirectory(joinRemotePath(_path, normalized)),
    );
  }

  Future<void> rename(RemoteFileEntry entry, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.contains('/')) {
      throw SftpFailure('文件名称无效。', path: entry.path);
    }
    await _mutate(
      () =>
          _requireSftp().rename(entry.path, joinRemotePath(_path, normalized)),
    );
  }

  Future<void> delete(RemoteFileEntry entry, {required bool recursive}) async {
    await _mutate(() => _requireSftp().delete(entry, recursive: recursive));
  }

  bool containsName(String name) => _entries.any((entry) => entry.name == name);

  Future<void> _mutate(Future<void> Function() operation) async {
    _mutating = true;
    _errorMessage = null;
    _notify();
    try {
      await operation();
      await load(_path);
    } on SftpFailure catch (error) {
      _errorMessage = error.message;
      rethrow;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  /// Borrows the session-wide browsing channel.
  ///
  /// The channel belongs to [SshSessionController], not to this controller: the
  /// drawer is rebuilt on every open, and opening a fresh SFTP channel each time
  /// exhausts the server's `MaxSessions` limit.
  Future<SftpSession> _ensureSftp() async {
    final existing = _sftp;
    if (existing != null && !existing.isClosed) return existing;
    final session = await _sshSession.openBrowseSftpSession();
    if (!_disposed) _sftp = session;
    return session;
  }

  SftpSession _requireSftp() {
    final sftp = _sftp;
    if (sftp == null || sftp.isClosed) {
      throw SftpFailure('SFTP 会话尚未就绪。', path: _path);
    }
    return sftp;
  }

  int _compareEntries(RemoteFileEntry left, RemoteFileEntry right) {
    if (left.isDirectory != right.isDirectory) return left.isDirectory ? -1 : 1;
    final result = switch (_sort) {
      RemoteFileSort.name => left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      ),
      RemoteFileSort.modified => _compareNullable(
        left.modifiedAt?.millisecondsSinceEpoch,
        right.modifiedAt?.millisecondsSinceEpoch,
      ),
      RemoteFileSort.size => _compareNullable(left.size, right.size),
    };
    return _ascending ? result : -result;
  }

  int _compareNullable(int? left, int? right) {
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_loadRevision;
    // The channel is owned by the SSH session and stays open for the next drawer
    // open; only the reference is dropped here.
    _sftp = null;
    super.dispose();
  }
}
