import 'package:flutter/foundation.dart';

import '../snippets/snippet_repository.dart';
import 'history_repository.dart';

enum HistoryListStatus { loading, ready, failure }

class HistoryController extends ChangeNotifier {
  HistoryController({
    required HistoryRepository repository,
    required SnippetRepository snippets,
    required String hostId,
  }) : _repository = repository,
       _snippets = snippets,
       _hostId = hostId;

  final HistoryRepository _repository;
  final SnippetRepository _snippets;
  final String _hostId;
  List<CommandHistoryEntry> _items = const [];
  HistoryListStatus _status = HistoryListStatus.loading;
  String _query = '';
  String? _errorMessage;
  bool _isMutating = false;
  bool _disposed = false;
  int _loadRevision = 0;

  List<CommandHistoryEntry> get items => _items;
  HistoryListStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isMutating => _isMutating;

  Future<void> load() async {
    final revision = ++_loadRevision;
    _status = HistoryListStatus.loading;
    _errorMessage = null;
    _notify();
    try {
      _items = await _repository.list(hostId: _hostId, query: _query);
      if (revision != _loadRevision) return;
      _status = HistoryListStatus.ready;
    } on HistoryRepositoryException catch (error) {
      if (revision != _loadRevision) return;
      _errorMessage = error.message;
      _status = HistoryListStatus.failure;
    }
    _notify();
  }

  Future<void> search(String query) async {
    if (_query == query.trim()) return;
    _query = query.trim();
    await load();
  }

  Future<void> togglePinned(CommandHistoryEntry entry) async {
    await _mutate(() => _repository.setPinned(entry, !entry.pinned));
  }

  Future<void> delete(CommandHistoryEntry entry) async {
    await _mutate(() => _repository.delete(entry.id));
  }

  Future<void> clear() async {
    await _mutate(() => _repository.clear(hostId: _hostId));
  }

  Future<void> convertToSnippet(
    CommandHistoryEntry entry, {
    required String name,
    required bool global,
  }) async {
    _isMutating = true;
    _errorMessage = null;
    _notify();
    try {
      await _snippets.save(
        SnippetDraft(
          name: name,
          command: entry.command,
          hostScope: global ? null : _hostId,
        ),
      );
    } on SnippetRepositoryException catch (error) {
      _errorMessage = error.message;
      rethrow;
    } finally {
      _isMutating = false;
      _notify();
    }
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    ++_loadRevision;
    _isMutating = true;
    _errorMessage = null;
    _notify();
    try {
      await operation();
      _items = await _repository.list(hostId: _hostId, query: _query);
      _status = HistoryListStatus.ready;
    } on HistoryRepositoryException catch (error) {
      _errorMessage = error.message;
      rethrow;
    } finally {
      _isMutating = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
