import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureCredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

  Future<void> write(String reference, String value) {
    return _storage.write(key: _key(reference), value: value);
  }

  Future<String?> read(String reference) {
    return _storage.read(key: _key(reference));
  }

  Future<void> delete(String reference) {
    return _storage.delete(key: _key(reference));
  }

  String _key(String reference) => 'credential:$reference';
}
