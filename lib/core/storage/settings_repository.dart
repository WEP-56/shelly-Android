import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../app/models.dart';
import 'app_database.dart';

class SettingsRepositoryException implements Exception {
  const SettingsRepositoryException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class SettingsRepository {
  SettingsRepository(this._database);

  static const _settingsKey = 'app_settings';
  static const _themeKey = 'theme_preference';

  final AppDatabase _database;

  Future<AppSettings> loadSettings() async {
    final value = await _read(_settingsKey);
    if (value == null) return const AppSettings();
    try {
      final json = jsonDecode(value);
      if (json is! Map) throw const FormatException();
      return AppSettings.fromJson(Map<String, Object?>.from(json));
    } on Object catch (error) {
      throw SettingsRepositoryException('读取应用设置失败，请重试。', cause: error);
    }
  }

  Future<ThemePreference> loadTheme() async {
    final value = await _read(_themeKey);
    return ThemePreference.values.firstWhere(
      (theme) => theme.name == value,
      orElse: () => ThemePreference.system,
    );
  }

  Future<void> saveSettings(AppSettings settings) {
    return _write(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<void> saveTheme(ThemePreference theme) {
    return _write(_themeKey, theme.name);
  }

  Future<String?> _read(String key) async {
    try {
      final rows = await _database.database.query(
        'app_settings',
        columns: ['json_value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.single['json_value'] as String;
    } on DatabaseException catch (error) {
      throw SettingsRepositoryException('读取应用设置失败，请重试。', cause: error);
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _database.database.insert('app_settings', {
        'key': key,
        'json_value': value,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } on DatabaseException catch (error) {
      throw SettingsRepositoryException('保存应用设置失败，请重试。', cause: error);
    }
  }
}
