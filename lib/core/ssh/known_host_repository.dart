import '../storage/app_database.dart';
import 'ssh_models.dart';

class KnownHostRepositoryException implements Exception {
  const KnownHostRepositoryException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class KnownHostRepository {
  KnownHostRepository(this._database);

  final AppDatabase _database;

  Future<KnownHostRecord?> find({
    required String host,
    required int port,
    required String algorithm,
  }) async {
    try {
      final rows = await _database.database.query(
        'known_hosts',
        where: 'host = ? AND port = ? AND algorithm = ?',
        whereArgs: [host, port, algorithm],
        limit: 1,
      );
      return rows.isEmpty ? null : _fromRow(rows.single);
    } on Object catch (error) {
      throw KnownHostRepositoryException('读取已知主机记录失败。', cause: error);
    }
  }

  Future<List<KnownHostRecord>> list() async {
    try {
      final rows = await _database.database.query(
        'known_hosts',
        orderBy: 'host COLLATE NOCASE, port, algorithm',
      );
      return rows.map(_fromRow).toList(growable: false);
    } on Object catch (error) {
      throw KnownHostRepositoryException('读取已知主机记录失败。', cause: error);
    }
  }

  Future<void> trust({
    required String host,
    required int port,
    required String algorithm,
    required String fingerprint,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    try {
      await _database.database.insert('known_hosts', {
        'host': host,
        'port': port,
        'algorithm': algorithm,
        'fingerprint': fingerprint,
        // dartssh2 exposes the SHA256 fingerprint but not the raw host key.
        'public_key': '',
        'first_seen_at': now,
        'last_seen_at': now,
      });
    } on Object catch (error) {
      throw KnownHostRepositoryException('保存主机指纹失败。', cause: error);
    }
  }

  Future<void> markSeen(KnownHostRecord record) async {
    try {
      await _database.database.update(
        'known_hosts',
        {'last_seen_at': DateTime.now().toUtc().millisecondsSinceEpoch},
        where: 'host = ? AND port = ? AND algorithm = ?',
        whereArgs: [record.host, record.port, record.algorithm],
      );
    } on Object catch (error) {
      throw KnownHostRepositoryException('更新主机指纹记录失败。', cause: error);
    }
  }

  Future<void> delete(KnownHostRecord record) async {
    try {
      await _database.database.delete(
        'known_hosts',
        where: 'host = ? AND port = ? AND algorithm = ?',
        whereArgs: [record.host, record.port, record.algorithm],
      );
    } on Object catch (error) {
      throw KnownHostRepositoryException('删除主机指纹失败，请重试。', cause: error);
    }
  }

  KnownHostRecord _fromRow(Map<String, Object?> row) {
    return KnownHostRecord(
      host: row['host']! as String,
      port: row['port']! as int,
      algorithm: row['algorithm']! as String,
      fingerprint: row['fingerprint']! as String,
      publicKey: row['public_key']! as String,
      firstSeenAt: DateTime.fromMillisecondsSinceEpoch(
        row['first_seen_at']! as int,
        isUtc: true,
      ),
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
        row['last_seen_at']! as int,
        isUtc: true,
      ),
    );
  }
}
