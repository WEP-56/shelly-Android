import 'package:uuid/uuid.dart';

import '../../core/storage/app_database.dart';

class HistoryRepositoryException implements Exception {
  const HistoryRepositoryException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class CommandHistoryEntry {
  const CommandHistoryEntry({
    required this.id,
    required this.sessionId,
    required this.hostId,
    required this.command,
    required this.startedAt,
    required this.finishedAt,
    required this.exitCode,
    required this.duration,
    required this.outputExcerpt,
    required this.pinned,
  });

  final String id;
  final String? sessionId;
  final String hostId;
  final String command;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final int? exitCode;
  final Duration? duration;
  final String? outputExcerpt;
  final bool pinned;
}

class HistoryRepository {
  HistoryRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  static const maxEntries = 2000;
  static const maxOutputExcerptLength = 4096;

  final AppDatabase _database;
  final Uuid _uuid;

  Future<List<CommandHistoryEntry>> list({
    required String hostId,
    String? query,
  }) async {
    final clauses = <String>['host_id = ?'];
    final arguments = <Object?>[hostId];
    final normalizedQuery = query?.trim();
    if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
      clauses.add("command LIKE ? ESCAPE '\\'");
      arguments.add('%${_escapeLike(normalizedQuery)}%');
    }
    try {
      final rows = await _database.database.query(
        'command_history',
        where: clauses.join(' AND '),
        whereArgs: arguments,
        orderBy: 'pinned DESC, started_at DESC',
      );
      return rows.map(_fromRow).toList(growable: false);
    } on Object catch (error) {
      throw HistoryRepositoryException('读取命令历史失败，请重试。', cause: error);
    }
  }

  Future<CommandHistoryEntry> record({
    required String hostId,
    required String command,
    String? sessionId,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? exitCode,
    Duration? duration,
    String? outputExcerpt,
  }) async {
    final normalizedCommand = command.trim();
    if (normalizedCommand.isEmpty) {
      throw const HistoryRepositoryException('空命令不会写入历史。');
    }
    final entry = CommandHistoryEntry(
      id: _uuid.v4(),
      sessionId: sessionId,
      hostId: hostId,
      command: normalizedCommand,
      startedAt: (startedAt ?? DateTime.now()).toUtc(),
      finishedAt: finishedAt?.toUtc(),
      exitCode: exitCode,
      duration: duration,
      outputExcerpt: _limitExcerpt(outputExcerpt),
      pinned: false,
    );
    try {
      await _database.database.transaction((transaction) async {
        await transaction.insert('command_history', _toRow(entry));
        await transaction.rawDelete(
          '''
          DELETE FROM command_history
          WHERE id IN (
            SELECT id FROM command_history
            ORDER BY pinned DESC, started_at DESC
            LIMIT -1 OFFSET ?
          )
        ''',
          [maxEntries],
        );
      });
      return entry;
    } on Object catch (error) {
      throw HistoryRepositoryException('保存命令历史失败。', cause: error);
    }
  }

  Future<void> setPinned(CommandHistoryEntry entry, bool pinned) async {
    try {
      await _database.database.update(
        'command_history',
        {'pinned': pinned ? 1 : 0},
        where: 'id = ?',
        whereArgs: [entry.id],
      );
    } on Object catch (error) {
      throw HistoryRepositoryException('更新命令历史失败，请重试。', cause: error);
    }
  }

  Future<void> delete(String id) async {
    try {
      await _database.database.delete(
        'command_history',
        where: 'id = ?',
        whereArgs: [id],
      );
    } on Object catch (error) {
      throw HistoryRepositoryException('删除命令历史失败，请重试。', cause: error);
    }
  }

  Future<void> clear({required String hostId}) async {
    try {
      await _database.database.delete(
        'command_history',
        where: 'host_id = ?',
        whereArgs: [hostId],
      );
    } on Object catch (error) {
      throw HistoryRepositoryException('清空命令历史失败，请重试。', cause: error);
    }
  }

  String? _limitExcerpt(String? excerpt) {
    if (excerpt == null || excerpt.isEmpty) return null;
    return excerpt.length <= maxOutputExcerptLength
        ? excerpt
        : excerpt.substring(excerpt.length - maxOutputExcerptLength);
  }

  CommandHistoryEntry _fromRow(Map<String, Object?> row) {
    final durationMs = row['duration_ms'] as int?;
    final finishedAt = row['finished_at'] as int?;
    return CommandHistoryEntry(
      id: row['id']! as String,
      sessionId: row['session_id'] as String?,
      hostId: row['host_id']! as String,
      command: row['command']! as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        row['started_at']! as int,
        isUtc: true,
      ),
      finishedAt: finishedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(finishedAt, isUtc: true),
      exitCode: row['exit_code'] as int?,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      outputExcerpt: row['output_excerpt'] as String?,
      pinned: row['pinned'] == 1,
    );
  }

  Map<String, Object?> _toRow(CommandHistoryEntry entry) => {
    'id': entry.id,
    'session_id': entry.sessionId,
    'host_id': entry.hostId,
    'command': entry.command,
    'started_at': entry.startedAt.millisecondsSinceEpoch,
    'finished_at': entry.finishedAt?.millisecondsSinceEpoch,
    'exit_code': entry.exitCode,
    'duration_ms': entry.duration?.inMilliseconds,
    'output_excerpt': entry.outputExcerpt,
    'pinned': entry.pinned ? 1 : 0,
  };

  String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
