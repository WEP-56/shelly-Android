import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'known_host_repository.dart';
import 'ssh_models.dart';

enum KnownHostsStatus { loading, ready, failure }

class KnownHostsController extends ChangeNotifier {
  KnownHostsController(this._repository);

  final KnownHostRepository _repository;
  final List<KnownHostRecord> _records = [];
  KnownHostsStatus _status = KnownHostsStatus.loading;
  String? _errorMessage;
  bool _disposed = false;

  UnmodifiableListView<KnownHostRecord> get records =>
      UnmodifiableListView(_records);
  KnownHostsStatus get status => _status;
  String? get errorMessage => _errorMessage;

  Future<void> load() async {
    _status = KnownHostsStatus.loading;
    _errorMessage = null;
    _notifyListeners();
    try {
      final records = await _repository.list();
      _records
        ..clear()
        ..addAll(records);
      _status = KnownHostsStatus.ready;
    } on KnownHostRepositoryException catch (error) {
      _errorMessage = error.message;
      _status = KnownHostsStatus.failure;
    }
    _notifyListeners();
  }

  Future<void> delete(KnownHostRecord record) async {
    await _repository.delete(record);
    _records.removeWhere(
      (item) =>
          item.host == record.host &&
          item.port == record.port &&
          item.algorithm == record.algorithm,
    );
    _notifyListeners();
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
