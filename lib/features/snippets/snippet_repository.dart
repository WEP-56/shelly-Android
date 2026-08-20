import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/app_database.dart';

class SnippetRepositoryException implements Exception {
  const SnippetRepositoryException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class CommandSnippet {
  const CommandSnippet({
    required this.id,
    required this.name,
    required this.command,
    required this.description,
    required this.tags,
    required this.hostScope,
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String command;
  final String description;
  final List<String> tags;
  final String? hostScope;
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class SnippetDraft {
  const SnippetDraft({
    required this.name,
    required this.command,
    this.description = '',
    this.tags = const [],
    this.hostScope,
  });

  final String name;
  final String command;
  final String description;
  final List<String> tags;
  final String? hostScope;
}

class SnippetRepository {
  SnippetRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Future<List<CommandSnippet>> list({String? query, String? hostId}) async {
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (hostId != null) {
      clauses.add('(host_scope IS NULL OR host_scope = ?)');
      arguments.add(hostId);
    }
    final normalizedQuery = query?.trim();
    if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
      clauses.add(
        "(name LIKE ? ESCAPE '\\' OR command LIKE ? ESCAPE '\\' "
        "OR description LIKE ? ESCAPE '\\' OR tags_json LIKE ? ESCAPE '\\')",
      );
      final pattern = '%${_escapeLike(normalizedQuery)}%';
      arguments.addAll([pattern, pattern, pattern, pattern]);
    }
    try {
      final rows = await _database.database.query(
        'snippets',
        where: clauses.isEmpty ? null : clauses.join(' AND '),
        whereArgs: arguments,
        orderBy: 'pinned DESC, updated_at DESC',
      );
      return rows.map(_fromRow).toList(growable: false);
    } on SnippetRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw SnippetRepositoryException('读取便签失败，请重试。', cause: error);
    }
  }

  Future<CommandSnippet> save(
    SnippetDraft draft, {
    CommandSnippet? existing,
  }) async {
    final name = draft.name.trim();
    final command = draft.command.trim();
    if (name.isEmpty || command.isEmpty) {
      throw const SnippetRepositoryException('名称和命令不能为空。');
    }
    final now = DateTime.now().toUtc();
    final snippet = CommandSnippet(
      id: existing?.id ?? _uuid.v4(),
      name: name,
      command: command,
      description: draft.description.trim(),
      tags: List.unmodifiable(
        draft.tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty),
      ),
      hostScope: draft.hostScope,
      pinned: existing?.pinned ?? false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    try {
      await _database.database.insert(
        'snippets',
        _toRow(snippet),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return snippet;
    } on Object catch (error) {
      throw SnippetRepositoryException('保存便签失败，请重试。', cause: error);
    }
  }

  Future<void> setPinned(CommandSnippet snippet, bool pinned) async {
    try {
      await _database.database.update(
        'snippets',
        {
          'pinned': pinned ? 1 : 0,
          'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [snippet.id],
      );
    } on Object catch (error) {
      throw SnippetRepositoryException('更新便签失败，请重试。', cause: error);
    }
  }

  Future<void> delete(String id) async {
    try {
      await _database.database.delete(
        'snippets',
        where: 'id = ?',
        whereArgs: [id],
      );
    } on Object catch (error) {
      throw SnippetRepositoryException('删除便签失败，请重试。', cause: error);
    }
  }

  CommandSnippet _fromRow(Map<String, Object?> row) {
    final decodedTags = jsonDecode(row['tags_json']! as String);
    if (decodedTags is! List) {
      throw const SnippetRepositoryException('便签标签数据无效。');
    }
    return CommandSnippet(
      id: row['id']! as String,
      name: row['name']! as String,
      command: row['command']! as String,
      description: row['description'] as String? ?? '',
      tags: List.unmodifiable(decodedTags.whereType<String>()),
      hostScope: row['host_scope'] as String?,
      pinned: row['pinned'] == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at']! as int,
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> _toRow(CommandSnippet snippet) => {
    'id': snippet.id,
    'name': snippet.name,
    'command': snippet.command,
    'description': snippet.description,
    'tags_json': jsonEncode(snippet.tags),
    'host_scope': snippet.hostScope,
    'pinned': snippet.pinned ? 1 : 0,
    'created_at': snippet.createdAt.millisecondsSinceEpoch,
    'updated_at': snippet.updatedAt.millisecondsSinceEpoch,
  };

  String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
