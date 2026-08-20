import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../app/models.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/secure_credential_store.dart';

class HostRepositoryException implements Exception {
  const HostRepositoryException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class HostRepository {
  HostRepository({
    required AppDatabase database,
    required SecureCredentialStore credentials,
    Uuid? uuid,
  }) : _database = database,
       _credentials = credentials,
       _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final SecureCredentialStore _credentials;
  final Uuid _uuid;

  Future<List<HostProfile>> list() async {
    try {
      final rows = await _database.database.query(
        'hosts',
        orderBy: 'updated_at DESC',
      );
      return rows.map(_fromRow).toList(growable: false);
    } on HostRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw HostRepositoryException('读取设备列表失败，请重试。', cause: error);
    }
  }

  Future<HostProfile> save(HostDraft draft, {HostProfile? existing}) async {
    final id = existing?.id ?? _uuid.v4();
    final credentialRef = existing?.credentialRef ?? _uuid.v4();
    final secret = draft.secret;
    if ((secret == null || secret.isEmpty) &&
        (existing == null ||
            existing.authType != draft.authType ||
            existing.credentialRef == null)) {
      throw const HostRepositoryException('认证资料不能为空。');
    }

    final now = DateTime.now().toUtc();
    final profile = HostProfile(
      id: id,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authType: draft.authType,
      credentialRef: credentialRef,
      lastPath: existing?.lastPath,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    String? previousSecret;
    var credentialChanged = false;
    try {
      if (secret != null && secret.isNotEmpty) {
        previousSecret = existing?.credentialRef == null
            ? null
            : await _credentials.read(credentialRef);
        await _credentials.write(credentialRef, secret);
        credentialChanged = true;
      }
      await _database.database.insert(
        'hosts',
        _toRow(profile),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return profile;
    } on HostRepositoryException {
      rethrow;
    } on Object catch (error) {
      if (credentialChanged) {
        try {
          if (previousSecret == null) {
            await _credentials.delete(credentialRef);
          } else {
            await _credentials.write(credentialRef, previousSecret);
          }
        } on Object catch (rollbackError) {
          throw HostRepositoryException(
            '保存设备失败，认证资料可能未同步，请重新编辑设备。',
            cause: rollbackError,
          );
        }
      }
      throw HostRepositoryException('保存设备失败，请重试。', cause: error);
    }
  }

  Future<void> delete(HostProfile profile) async {
    String? storedSecret;
    try {
      if (profile.credentialRef != null) {
        storedSecret = await _credentials.read(profile.credentialRef!);
      }
      final deleted = await _database.database.delete(
        'hosts',
        where: 'id = ?',
        whereArgs: [profile.id],
      );
      if (deleted == 0) return;
      if (profile.credentialRef != null) {
        try {
          await _credentials.delete(profile.credentialRef!);
        } on Object {
          await _database.database.insert(
            'hosts',
            _toRow(profile),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (storedSecret != null) {
            await _credentials.write(profile.credentialRef!, storedSecret);
          }
          rethrow;
        }
      }
    } on HostRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw HostRepositoryException('删除设备失败，请重试。', cause: error);
    }
  }

  Future<String?> readCredential(HostProfile profile) {
    final reference = profile.credentialRef;
    if (reference == null) return Future<String?>.value();
    return _credentials.read(reference);
  }

  HostProfile _fromRow(Map<String, Object?> row) {
    final authName = row['auth_type'] as String;
    final authType = HostAuthType.values.firstWhere(
      (value) => value.name == authName,
      orElse: () => throw const HostRepositoryException('设备认证类型无效。'),
    );
    return HostProfile(
      id: row['id']! as String,
      name: row['name']! as String,
      host: row['host']! as String,
      port: row['port']! as int,
      username: row['username']! as String,
      authType: authType,
      credentialRef: row['credential_ref'] as String?,
      lastPath: row['last_path'] as String?,
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

  Map<String, Object?> _toRow(HostProfile profile) => {
    'id': profile.id,
    'name': profile.name,
    'host': profile.host,
    'port': profile.port,
    'username': profile.username,
    'auth_type': profile.authType.name,
    'credential_ref': profile.credentialRef,
    'last_path': profile.lastPath,
    'created_at': profile.createdAt.millisecondsSinceEpoch,
    'updated_at': profile.updatedAt.millisecondsSinceEpoch,
  };
}
