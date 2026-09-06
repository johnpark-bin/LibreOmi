/// Key/value storage for secrets (API keys) that must never be written to
/// disk in plaintext.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A minimal key/value store for values that must not be written in plaintext.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// [SecretStore] backed by `package:flutter_secure_storage`.
///
/// This uses the *default* [AndroidOptions] rather than opting into
/// `encryptedSharedPreferences`. As of flutter_secure_storage 10.x that
/// parameter is `@Deprecated` and explicitly documented as ignored ("Remove
/// this parameter - it will be ignored"), because Google deprecated Jetpack
/// Security. The 10.x default path already wraps the encryption key in the
/// Android Keystore (`RSA_ECB_OAEPwithSHA_256andMGF1Padding`) and encrypts
/// the stored values with `AES_GCM_NoPadding`, so there is nothing to gain by
/// passing it — do not "fix" this back in without re-reading the changelog.
class SecureStorageSecretStore implements SecretStore {
  SecureStorageSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory [SecretStore] for tests. Values can be seeded up front and are
/// exposed read-only so a test can assert on what was written without poking
/// at private state.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? initial])
      : _values = Map<String, String>.from(initial ?? const {});

  final Map<String, String> _values;

  /// When true, every method throws — used to simulate a broken keystore or
  /// a missing plugin so callers can be tested for graceful degradation.
  bool failing = false;

  /// Keys whose [write] throws while the rest of the store keeps working.
  /// Lets a test drive a *partial* failure, which is the interesting case for
  /// a multi-key migration: one secret crosses over and the other does not.
  final Set<String> failWritesFor = <String>{};

  /// Read-only view of what has been written so far.
  Map<String, String> get values => Map.unmodifiable(_values);

  @override
  Future<String?> read(String key) async {
    if (failing) throw Exception('InMemorySecretStore: simulated failure');
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failing) throw Exception('InMemorySecretStore: simulated failure');
    if (failWritesFor.contains(key)) {
      throw Exception('InMemorySecretStore: simulated write failure for "$key"');
    }
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failing) throw Exception('InMemorySecretStore: simulated failure');
    _values.remove(key);
  }
}
