import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';
import '../domain/agent_message.dart';

class AgentSessionException implements Exception {
  const AgentSessionException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class AgentSessionSummary {
  const AgentSessionSummary({
    required this.id,
    required this.hostId,
    required this.title,
    required this.messageCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String hostId;
  final String title;
  final int messageCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isEmpty => messageCount == 0;
}

/// Persists agent conversations per host.
///
/// Only rendered transcript content is stored. Tool results are already bounded
/// and non-secret by construction, and provider API keys never enter a message,
/// so nothing here needs secure storage.
class AgentSessionRepository {
  AgentSessionRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  static const maxSessionsPerHost = 50;
  static const _titleMaxLength = 60;

  final AppDatabase _database;
  final Uuid _uuid;

  Future<List<AgentSessionSummary>> list({String? hostId}) async {
    try {
      final rows = await _database.database.rawQuery(
        '''
        SELECT s.id, s.host_id, s.title, s.created_at, s.updated_at,
               (SELECT COUNT(*) FROM agent_messages m WHERE m.session_id = s.id) AS message_count
        FROM agent_sessions s
        ${hostId == null ? '' : 'WHERE s.host_id = ?'}
        ORDER BY s.updated_at DESC
        ''',
        [?hostId],
      );
      return rows.map(_summaryFromRow).toList(growable: false);
    } on Object catch (error) {
      throw AgentSessionException('读取 Agent 会话失败，请重试。', cause: error);
    }
  }

  Future<AgentSessionSummary> create({
    required String hostId,
    String? title,
  }) async {
    final now = DateTime.now().toUtc();
    final summary = AgentSessionSummary(
      id: _uuid.v4(),
      hostId: hostId,
      title: _normalizeTitle(title) ?? '新会话',
      messageCount: 0,
      createdAt: now,
      updatedAt: now,
    );
    try {
      await _database.database.insert('agent_sessions', {
        'id': summary.id,
        'host_id': summary.hostId,
        'title': summary.title,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      await _pruneHostSessions(hostId);
    } on Object catch (error) {
      throw AgentSessionException('创建 Agent 会话失败，请重试。', cause: error);
    }
    return summary;
  }

  Future<List<AgentMessage>> loadTranscript(String sessionId) async {
    try {
      final rows = await _database.database.query(
        'agent_messages',
        columns: ['json_value'],
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'seq ASC',
      );
      final messages = <AgentMessage>[];
      for (final row in rows) {
        final json = jsonDecode(row['json_value']! as String);
        if (json is! Map) continue;
        final message = AgentMessage.fromJson(Map<String, Object?>.from(json));
        if (message != null) messages.add(message);
      }
      return messages;
    } on Object catch (error) {
      throw AgentSessionException('读取 Agent 会话记录失败，请重试。', cause: error);
    }
  }

  /// Replaces the stored transcript. Called after each turn settles so a run that
  /// is cancelled mid-stream still persists what the user saw.
  Future<void> saveTranscript(
    String sessionId,
    List<AgentMessage> messages, {
    String? title,
  }) async {
    final now = DateTime.now().toUtc();
    try {
      await _database.database.transaction((transaction) async {
        await transaction.delete(
          'agent_messages',
          where: 'session_id = ?',
          whereArgs: [sessionId],
        );
        for (var index = 0; index < messages.length; index++) {
          final message = messages[index];
          await transaction.insert('agent_messages', {
            'id': _uuid.v4(),
            'session_id': sessionId,
            'seq': index,
            'role': message.role,
            'json_value': jsonEncode(message.toJson()),
            'created_at': message.timestamp.toUtc().millisecondsSinceEpoch,
          });
        }
        final normalizedTitle = _normalizeTitle(title);
        await transaction.update(
          'agent_sessions',
          {'updated_at': now.millisecondsSinceEpoch, 'title': ?normalizedTitle},
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } on Object catch (error) {
      throw AgentSessionException('保存 Agent 会话记录失败。', cause: error);
    }
  }

  Future<void> rename(String sessionId, String title) async {
    final normalized = _normalizeTitle(title);
    if (normalized == null) {
      throw const AgentSessionException('会话名称不能为空。');
    }
    try {
      await _database.database.update(
        'agent_sessions',
        {
          'title': normalized,
          'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    } on Object catch (error) {
      throw AgentSessionException('重命名 Agent 会话失败，请重试。', cause: error);
    }
  }

  Future<void> delete(String sessionId) async {
    try {
      await _database.database.transaction((transaction) async {
        await transaction.delete(
          'agent_messages',
          where: 'session_id = ?',
          whereArgs: [sessionId],
        );
        await transaction.delete(
          'agent_sessions',
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } on Object catch (error) {
      throw AgentSessionException('删除 Agent 会话失败，请重试。', cause: error);
    }
  }

  Future<void> clear({String? hostId}) async {
    try {
      await _database.database.transaction((transaction) async {
        if (hostId == null) {
          await transaction.delete('agent_messages');
          await transaction.delete('agent_sessions');
          return;
        }
        await transaction.rawDelete(
          '''
          DELETE FROM agent_messages
          WHERE session_id IN (SELECT id FROM agent_sessions WHERE host_id = ?)
          ''',
          [hostId],
        );
        await transaction.delete(
          'agent_sessions',
          where: 'host_id = ?',
          whereArgs: [hostId],
        );
      });
    } on Object catch (error) {
      throw AgentSessionException('清空 Agent 会话失败，请重试。', cause: error);
    }
  }

  /// Derives a session title from the first user message.
  static String titleFromTranscript(List<AgentMessage> messages) {
    for (final message in messages) {
      if (message is! AgentUserMessage) continue;
      final text = message.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      return text.length <= 28 ? text : '${text.substring(0, 28)}…';
    }
    return '新会话';
  }

  Future<void> _pruneHostSessions(String hostId) async {
    await _database.database.rawDelete(
      '''
      DELETE FROM agent_messages
      WHERE session_id IN (
        SELECT id FROM agent_sessions
        WHERE host_id = ?
        ORDER BY updated_at DESC
        LIMIT -1 OFFSET ?
      )
      ''',
      [hostId, maxSessionsPerHost],
    );
    await _database.database.rawDelete(
      '''
      DELETE FROM agent_sessions
      WHERE id IN (
        SELECT id FROM agent_sessions
        WHERE host_id = ?
        ORDER BY updated_at DESC
        LIMIT -1 OFFSET ?
      )
      ''',
      [hostId, maxSessionsPerHost],
    );
  }

  String? _normalizeTitle(String? title) {
    final trimmed = title?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.length <= _titleMaxLength
        ? trimmed
        : trimmed.substring(0, _titleMaxLength);
  }

  AgentSessionSummary _summaryFromRow(Map<String, Object?> row) {
    return AgentSessionSummary(
      id: row['id']! as String,
      hostId: row['host_id']! as String,
      title: row['title']! as String,
      messageCount: (row['message_count'] as num?)?.toInt() ?? 0,
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
}
