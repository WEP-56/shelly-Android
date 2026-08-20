import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../app/models.dart';
import '../data/host_repository.dart';

enum HostListStatus { loading, ready, failure }

class HostController extends ChangeNotifier {
  HostController(this._repository);

  final HostRepository _repository;
  final List<HostProfile> _hosts = [];

  HostListStatus _status = HostListStatus.loading;
  String? _loadError;
  bool _isMutating = false;
  bool _disposed = false;

  UnmodifiableListView<HostProfile> get hosts => UnmodifiableListView(_hosts);
  HostListStatus get status => _status;
  String? get loadError => _loadError;
  bool get isMutating => _isMutating;

  Future<void> load() async {
    _status = HostListStatus.loading;
    _loadError = null;
    _notifyListeners();
    try {
      final hosts = await _repository.list();
      _hosts
        ..clear()
        ..addAll(hosts);
      _status = HostListStatus.ready;
    } on HostRepositoryException catch (error) {
      _loadError = error.message;
      _status = HostListStatus.failure;
    }
    _notifyListeners();
  }

  Future<void> save(HostSaveRequest request) async {
    _ensureNotMutating();
    _setMutating(true);
    try {
      final host = await _repository.save(
        request.draft,
        existing: request.existing,
      );
      final index = _hosts.indexWhere((item) => item.id == host.id);
      if (index == -1) {
        _hosts.insert(0, host);
      } else {
        _hosts[index] = host;
        _hosts.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      }
      _notifyListeners();
    } finally {
      _setMutating(false);
    }
  }

  Future<void> delete(HostProfile host) async {
    _ensureNotMutating();
    _setMutating(true);
    try {
      await _repository.delete(host);
      _hosts.removeWhere((item) => item.id == host.id);
      _notifyListeners();
    } finally {
      _setMutating(false);
    }
  }

  void _setMutating(bool value) {
    if (_isMutating == value) return;
    _isMutating = value;
    _notifyListeners();
  }

  void _ensureNotMutating() {
    if (_isMutating) {
      throw const HostRepositoryException('另一项设备操作正在进行，请稍后重试。');
    }
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
