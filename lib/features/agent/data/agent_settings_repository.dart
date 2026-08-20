import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/storage/secure_credential_store.dart';
import '../domain/agent_provider_config.dart';

class AgentSettingsException implements Exception {
  const AgentSettingsException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Owns agent provider rows and the Web Search config.
///
/// API keys only ever move between the caller and [SecureCredentialStore]; the
/// SQLite row stores an opaque `credential_ref`. Deleting a provider deletes its
/// secret in the same call so no orphan key survives.
class AgentSettingsRepository {
  AgentSettingsRepository({
    required AppDatabase database,
    required SecureCredentialStore credentials,
    Uuid? uuid,
  }) : _database = database,
       _credentials = credentials,
       _uuid = uuid ?? const Uuid();

  static const _table = 'agent_providers';
  static const _webSearchKey = 'agent_web_search';
  static const _webSearchCredentialRef = 'agent-web-search';
  static const _workSpecKey = 'agent_work_spec';
  static const workSpecMaxLength = 8000;

  final AppDatabase _database;
  final SecureCredentialStore _credentials;
  final Uuid _uuid;

  Future<List<AgentProviderConfig>> listProviders() async {
    try {
      final rows = await _database.database.query(
        _table,
        orderBy: 'is_default DESC, created_at ASC',
      );
      return rows.map(_fromRow).toList(growable: false);
    } on Object catch (error) {
      throw AgentSettingsException('读取 Agent Provider 失败，请重试。', cause: error);
    }
  }

  Future<AgentProviderConfig?> loadDefaultProvider() async {
    final providers = await listProviders();
    if (providers.isEmpty) return null;
    return providers.firstWhere(
      (provider) => provider.isDefault,
      orElse: () => providers.first,
    );
  }

  Future<AgentProviderConfig> createProvider(AgentProviderDraft draft) async {
    final now = DateTime.now().toUtc();
    final existing = await listProviders();
    final apiKey = draft.apiKey?.trim();
    final credentialRef = apiKey == null || apiKey.isEmpty
        ? null
        : newAgentCredentialRef(_uuid);
    final provider = AgentProviderConfig(
      id: _uuid.v4(),
      name: draft.name.trim(),
      protocol: draft.protocol,
      endpoint: draft.endpoint.trim(),
      model: draft.model.trim(),
      credentialRef: credentialRef,
      timeout: draft.timeout,
      maxLoops: draft.maxLoops,
      maxOutputTokens: draft.maxOutputTokens,
      isDefault: existing.isEmpty,
      createdAt: now,
      updatedAt: now,
    );
    if (credentialRef != null) {
      await _writeSecret(credentialRef, apiKey!);
    }
    try {
      await _database.database.insert(_table, _toRow(provider));
    } on Object catch (error) {
      if (credentialRef != null) await _deleteSecret(credentialRef);
      throw AgentSettingsException('保存 Agent Provider 失败，请重试。', cause: error);
    }
    return provider;
  }

  /// Updates a provider. A null [draft.apiKey] keeps the stored key; an empty
  /// string clears it.
  Future<AgentProviderConfig> updateProvider(
    AgentProviderConfig existing,
    AgentProviderDraft draft,
  ) async {
    final apiKey = draft.apiKey;
    var credentialRef = existing.credentialRef;
    if (apiKey != null) {
      final trimmed = apiKey.trim();
      if (trimmed.isEmpty) {
        if (credentialRef != null) await _deleteSecret(credentialRef);
        credentialRef = null;
      } else {
        credentialRef ??= newAgentCredentialRef(_uuid);
        await _writeSecret(credentialRef, trimmed);
      }
    }
    final updated = AgentProviderConfig(
      id: existing.id,
      name: draft.name.trim(),
      protocol: draft.protocol,
      endpoint: draft.endpoint.trim(),
      model: draft.model.trim(),
      credentialRef: credentialRef,
      timeout: draft.timeout,
      maxLoops: draft.maxLoops,
      maxOutputTokens: draft.maxOutputTokens,
      isDefault: existing.isDefault,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
    try {
      await _database.database.update(
        _table,
        _toRow(updated),
        where: 'id = ?',
        whereArgs: [updated.id],
      );
    } on Object catch (error) {
      throw AgentSettingsException('更新 Agent Provider 失败，请重试。', cause: error);
    }
    return updated;
  }

  Future<void> deleteProvider(AgentProviderConfig provider) async {
    try {
      await _database.database.delete(
        _table,
        where: 'id = ?',
        whereArgs: [provider.id],
      );
    } on Object catch (error) {
      throw AgentSettingsException('删除 Agent Provider 失败，请重试。', cause: error);
    }
    final credentialRef = provider.credentialRef;
    if (credentialRef != null) await _deleteSecret(credentialRef);
    if (!provider.isDefault) return;
    final remaining = await listProviders();
    if (remaining.isNotEmpty) await setDefaultProvider(remaining.first);
  }

  Future<void> setDefaultProvider(AgentProviderConfig provider) async {
    try {
      await _database.database.transaction((transaction) async {
        await transaction.update(_table, {'is_default': 0});
        await transaction.update(
          _table,
          {'is_default': 1},
          where: 'id = ?',
          whereArgs: [provider.id],
        );
      });
    } on Object catch (error) {
      throw AgentSettingsException('设置默认 Provider 失败，请重试。', cause: error);
    }
  }

  /// Reads the API key for a request. Callers must not log or persist the value.
  Future<String?> readApiKey(AgentProviderConfig provider) async {
    final credentialRef = provider.credentialRef;
    if (credentialRef == null) return null;
    try {
      final value = await _credentials.read(credentialRef);
      return value == null || value.isEmpty ? null : value;
    } on Object catch (error) {
      throw AgentSettingsException('读取 Provider API Key 失败。', cause: error);
    }
  }

  Future<WebSearchConfig> loadWebSearch() async {
    try {
      final rows = await _database.database.query(
        'app_settings',
        columns: ['json_value'],
        where: 'key = ?',
        whereArgs: [_webSearchKey],
        limit: 1,
      );
      if (rows.isEmpty) return const WebSearchConfig();
      final json = jsonDecode(rows.single['json_value']! as String);
      if (json is! Map) return const WebSearchConfig();
      return WebSearchConfig.fromJson(Map<String, Object?>.from(json));
    } on Object catch (error) {
      throw AgentSettingsException('读取 Web Search 设置失败。', cause: error);
    }
  }

  /// Saves the Web Search config. A null [apiKey] keeps the stored key; an empty
  /// string clears it.
  Future<WebSearchConfig> saveWebSearch(
    WebSearchConfig config, {
    String? apiKey,
  }) async {
    var credentialRef = config.credentialRef;
    if (apiKey != null) {
      final trimmed = apiKey.trim();
      if (trimmed.isEmpty) {
        if (credentialRef != null) await _deleteSecret(credentialRef);
        credentialRef = null;
      } else {
        credentialRef ??= _webSearchCredentialRef;
        await _writeSecret(credentialRef, trimmed);
      }
    }
    // Built explicitly instead of via copyWith: copyWith keeps the old reference
    // for a null argument, which would leave a dangling ref after a clear.
    final updated = WebSearchConfig(
      enabled: config.enabled,
      endpoint: config.endpoint,
      credentialRef: credentialRef,
      timeout: config.timeout,
      maxResults: config.maxResults,
    );
    try {
      await _database.database.insert('app_settings', {
        'key': _webSearchKey,
        'json_value': jsonEncode(updated.toJson()),
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } on Object catch (error) {
      throw AgentSettingsException('保存 Web Search 设置失败。', cause: error);
    }
    return updated;
  }

  Future<String?> readWebSearchKey(WebSearchConfig config) async {
    final credentialRef = config.credentialRef;
    if (credentialRef == null) return null;
    try {
      final value = await _credentials.read(credentialRef);
      return value == null || value.isEmpty ? null : value;
    } on Object catch (error) {
      throw AgentSettingsException('读取 Web Search API Key 失败。', cause: error);
    }
  }

  /// Reads the user-authored work spec (AGENTS.md style) shown to the model as
  /// lower-priority guidance. Never contains secrets by policy; the UI says so.
  Future<String> loadWorkSpec() async {
    try {
      final rows = await _database.database.query(
        'app_settings',
        columns: ['json_value'],
        where: 'key = ?',
        whereArgs: [_workSpecKey],
        limit: 1,
      );
      if (rows.isEmpty) return '';
      final json = jsonDecode(rows.single['json_value']! as String);
      if (json is! Map) return '';
      return json['text'] as String? ?? '';
    } on Object catch (error) {
      throw AgentSettingsException('读取 Agent 工作规范失败。', cause: error);
    }
  }

  Future<String> saveWorkSpec(String spec) async {
    final trimmed = spec.trim();
    final limited = trimmed.length <= workSpecMaxLength
        ? trimmed
        : trimmed.substring(0, workSpecMaxLength);
    try {
      await _database.database.insert('app_settings', {
        'key': _workSpecKey,
        'json_value': jsonEncode({'text': limited}),
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } on Object catch (error) {
      throw AgentSettingsException('保存 Agent 工作规范失败。', cause: error);
    }
    return limited;
  }

  Future<void> _writeSecret(String reference, String value) async {
    try {
      await _credentials.write(reference, value);
    } on Object catch (error) {
      throw AgentSettingsException('写入安全存储失败，请重试。', cause: error);
    }
  }

  Future<void> _deleteSecret(String reference) async {
    try {
      await _credentials.delete(reference);
    } on Object catch (error) {
      throw AgentSettingsException('清理安全存储失败，请重试。', cause: error);
    }
  }

  AgentProviderConfig _fromRow(Map<String, Object?> row) {
    return AgentProviderConfig(
      id: row['id']! as String,
      name: row['name']! as String,
      protocol: AgentProviderProtocol.fromId(row['protocol'] as String?),
      endpoint: row['endpoint']! as String,
      model: row['model']! as String,
      credentialRef: row['credential_ref'] as String?,
      timeout: Duration(milliseconds: row['timeout_ms']! as int),
      maxLoops: row['max_loops']! as int,
      maxOutputTokens: row['max_output_tokens']! as int,
      isDefault: row['is_default'] == 1,
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

  Map<String, Object?> _toRow(AgentProviderConfig provider) => {
    'id': provider.id,
    'name': provider.name,
    'protocol': provider.protocol.id,
    'endpoint': provider.endpoint,
    'model': provider.model,
    'credential_ref': provider.credentialRef,
    'timeout_ms': provider.timeout.inMilliseconds,
    'max_loops': provider.maxLoops,
    'max_output_tokens': provider.maxOutputTokens,
    'is_default': provider.isDefault ? 1 : 0,
    'created_at': provider.createdAt.millisecondsSinceEpoch,
    'updated_at': provider.updatedAt.millisecondsSinceEpoch,
  };
}
