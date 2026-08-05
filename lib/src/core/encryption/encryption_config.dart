import 'dart:typed_data';

import '../errors/exceptions.dart';
import 'encryption_type.dart';
import 'key_derivation.dart';

/// Sealed configuration describing how a database encrypts values.
///
/// The constructors make misuse impossible by construction: real key material
/// (a raw 32-byte key or a passphrase run through PBKDF2) is required for
/// AES-256, and the obfuscation mode is explicitly named so it can never be
/// mistaken for encryption. There is no constructor that derives a key from a
/// database name or any other guessable value.
///
/// Key material passed here is never logged by ReaxDB at any log level.
sealed class EncryptionConfig {
  const EncryptionConfig._();

  /// No encryption. Values are stored as plaintext.
  const factory EncryptionConfig.none() = NoEncryptionConfig._;

  /// AES-256-GCM with a caller-provided raw 32-byte key.
  ///
  /// Use this when you already manage key material (for example from a
  /// platform keystore). Throws [EncryptionException] if [key] is not exactly
  /// 32 bytes. The key is copied defensively.
  factory EncryptionConfig.aes256({required Uint8List key}) = Aes256KeyConfig._;

  /// AES-256-GCM with a key derived from [passphrase] using
  /// PBKDF2-HMAC-SHA256.
  ///
  /// The salt is per-database: generated randomly on first open, persisted in
  /// the database metadata, and supplied to the engine on every subsequent
  /// open. [iterations] defaults to [KeyDerivation.defaultIterations]
  /// (OWASP-recommended) and must be at least [KeyDerivation.minIterations].
  factory EncryptionConfig.aes256FromPassphrase({
    required String passphrase,
    int iterations,
  }) = Aes256PassphraseConfig._;

  /// Repeating-key XOR obfuscation. **NOT secure.**
  ///
  /// This mode provides no confidentiality against any real attacker and no
  /// integrity protection; it only stops values from being casually readable
  /// on disk. Never use it for sensitive data — use
  /// [EncryptionConfig.aes256] instead. Throws [EncryptionException] if
  /// [key] is empty.
  factory EncryptionConfig.obfuscation({required Uint8List key}) =
      ObfuscationConfig._;

  /// The algorithm this configuration selects.
  EncryptionType get type;

  @override
  String toString() => 'EncryptionConfig(${type.name})';
}

/// Configuration for [EncryptionType.none].
final class NoEncryptionConfig extends EncryptionConfig {
  const NoEncryptionConfig._() : super._();

  @override
  EncryptionType get type => EncryptionType.none;
}

/// Configuration for AES-256-GCM with a raw key.
final class Aes256KeyConfig extends EncryptionConfig {
  Aes256KeyConfig._({required Uint8List key})
    : key = Uint8List.fromList(key),
      super._() {
    if (key.length != KeyDerivation.keyLength) {
      throw EncryptionException(
        'AES-256 requires a ${KeyDerivation.keyLength}-byte key '
        '(got ${key.length} bytes)',
      );
    }
  }

  /// The raw 256-bit AES key. Never logged.
  final Uint8List key;

  @override
  EncryptionType get type => EncryptionType.aes256;
}

/// Configuration for AES-256-GCM with a PBKDF2-derived key.
final class Aes256PassphraseConfig extends EncryptionConfig {
  Aes256PassphraseConfig._({
    required this.passphrase,
    this.iterations = KeyDerivation.defaultIterations,
  }) : super._() {
    if (passphrase.isEmpty) {
      throw const EncryptionException('Passphrase must not be empty');
    }
    if (iterations < KeyDerivation.minIterations) {
      throw EncryptionException(
        'PBKDF2 iteration count must be at least '
        '${KeyDerivation.minIterations} (got $iterations)',
      );
    }
  }

  /// The user passphrase. Never logged.
  final String passphrase;

  /// PBKDF2-HMAC-SHA256 iteration count.
  final int iterations;

  @override
  EncryptionType get type => EncryptionType.aes256;
}

/// Configuration for [EncryptionType.obfuscation]. **NOT secure.**
final class ObfuscationConfig extends EncryptionConfig {
  ObfuscationConfig._({required Uint8List key})
    : key = Uint8List.fromList(key),
      super._() {
    if (key.isEmpty) {
      throw const EncryptionException('Obfuscation key must not be empty');
    }
  }

  /// The XOR key. Never logged.
  final Uint8List key;

  @override
  EncryptionType get type => EncryptionType.obfuscation;
}
