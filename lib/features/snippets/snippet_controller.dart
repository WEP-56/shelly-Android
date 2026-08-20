import 'package:flutter/foundation.dart';

import 'snippet_repository.dart';

enum SnippetListStatus { loading, ready, failure }

class SnippetController extends ChangeNotifier {
  SnippetController({
    required SnippetRepository repository,
    required String hostId,
  }) : _repository = repository,
       _hostId = hostId;

  final SnippetRepository _repository;
  final String _hostId;
  List<CommandSnippet> _items = const [];
  SnippetListStatus _status = SnippetListStatus.loading;
  String _query = '';
  String? _errorMessage;
  bool _isMutating = false;
  bool _disposed = false;
  int _loadRevision = 0;

  List<CommandSnippet> get items => _items;
  SnippetListStatus get status => _status;
  String get query => _query;
  String? get errorMessage => _errorMessage;
  bool get isMutating => _isMutating;

  Future<void> load() async {
    final revision = ++_loadRevision;
    _status = SnippetListStatus.loading;
    _errorMessage = null;
    _notify();
    try {
      _items = await _repository.list(query: _query, hostId: _hostId);
      if (revision != _loadRevision) return;
      _status = SnippetListStatus.ready;
    } on SnippetRepositoryException catch (error) {
      if (revision != _loadRevision) return;
      _errorMessage = error.message;
      _status = SnippetListStatus.failure;
    }
    _notify();
  }

  Future<void> search(String query) async {
    if (_query == query.trim()) return;
    _query = query.trim();
    await load();
  }

  Future<void> save(SnippetDraft draft, {CommandSnippet? existing}) async {
    await _mutate(() => _repository.save(draft, existing: existing));
  }

  Future<void> togglePinned(CommandSnippet snippet) async {
    await _mutate(() => _repository.setPinned(snippet, !snippet.pinned));
  }

  Future<void> delete(CommandSnippet snippet) async {
    await _mutate(() => _repository.delete(snippet.id));
  }

  Future<void> _mutate(Future<Object?> Function() operation) async {
    ++_loadRevision;
    _isMutating = true;
    _errorMessage = null;
    _notify();
    try {
      await operation();
      _items = await _repository.list(query: _query, hostId: _hostId);
      _status = SnippetListStatus.ready;
    } on SnippetRepositoryException catch (error) {
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
