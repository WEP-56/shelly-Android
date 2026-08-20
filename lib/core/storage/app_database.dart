import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this._database);

  final Database _database;

  static Future<AppDatabase> open() async {
    final root = await getDatabasesPath();
    final database = await openDatabase(
      path.join(root, 'shelly.db'),
      version: 1,
      onCreate: (database, version) async {
        await _migrate(database, 0, version);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        await _migrate(database, oldVersion, newVersion);
      },
    );
    return AppDatabase._(database);
  }

  Database get database => _database;

  Future<void> close() => _database.close();

  static Future<void> _migrate(
    DatabaseExecutor database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 1 && newVersion >= 1) await _createVersion1(database);
  }

  static Future<void> _createVersion1(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE hosts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL,
        username TEXT NOT NULL,
        auth_type TEXT NOT NULL,
        credential_ref TEXT,
        last_path TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE known_hosts (
        host TEXT NOT NULL,
        port INTEGER NOT NULL,
        algorithm TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        public_key TEXT NOT NULL,
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        PRIMARY KEY (host, port, algorithm)
      )
    ''');
    await database.execute('''
      CREATE TABLE snippets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        command TEXT NOT NULL,
        description TEXT,
        tags_json TEXT NOT NULL,
        host_scope TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE command_history (
        id TEXT PRIMARY KEY,
        session_id TEXT,
        host_id TEXT NOT NULL,
        command TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        exit_code INTEGER,
        duration_ms INTEGER,
        output_excerpt TEXT,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        json_value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }
}
