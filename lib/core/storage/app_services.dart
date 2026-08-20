import '../ssh/known_host_repository.dart';
import '../ssh/ssh_connection_factory.dart';
import '../../features/hosts/data/host_repository.dart';
import 'app_database.dart';
import 'secure_credential_store.dart';
import 'settings_repository.dart';

class AppServices {
  AppServices._({
    required this.database,
    required this.hosts,
    required this.knownHosts,
    required this.settings,
    required this.sshConnections,
  });

  final AppDatabase database;
  final HostRepository hosts;
  final KnownHostRepository knownHosts;
  final SettingsRepository settings;
  final SshConnectionFactory sshConnections;

  static Future<AppServices> open() async {
    final database = await AppDatabase.open();
    final credentials = SecureCredentialStore();
    final hosts = HostRepository(database: database, credentials: credentials);
    final knownHosts = KnownHostRepository(database);
    return AppServices._(
      database: database,
      hosts: hosts,
      knownHosts: knownHosts,
      settings: SettingsRepository(database),
      sshConnections: SshConnectionFactory(
        hosts: hosts,
        knownHosts: knownHosts,
      ),
    );
  }

  Future<void> close() => database.close();
}
