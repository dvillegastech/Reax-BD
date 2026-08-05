/// Read-only reimplementation of the ReaxDB 1.x encryption scheme.
///
/// This file exists for ONE purpose: decrypting data written by ReaxDB 1.x so
/// that [LegacyMigration] can move it into a 2.x database. It deliberately
/// offers no way to encrypt.
///
/// The 1.x scheme is not safe by modern standards and must never protect newly
/// written data:
///
/// * The AES key was derived with 10,001 unsalted-per-database SHA-256 rounds
///   over `password + 'ReaxDB_Salt_v1_2025'`. The salt is a compile-time
///   constant, so the same passphrase always produced the same key and rainbow
///   tables are trivial to build.
/// * The AES-GCM nonce was `millisecondsSinceEpoch || counter`, with the
///   counter reset on every process start. Two records written in the same
///   millisecond by two different runs reuse a nonce, which breaks GCM.
/// * The `xor` mode is a repeating 512-byte keystream. It is obfuscation, not
///   encryption.
///
/// Migrated databases are re-encrypted with the 2.x scheme (PBKDF2 with a
/// random per-database salt and AES-GCM with a random IV).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../core/errors/exceptions.dart';

/// The cipher a ReaxDB 1.x database was written with.
///
/// ReaxDB 1.x stored no marker describing which of these was used, so the
/// migrator probes the candidates against real records; see
/// [LegacyMigration.migrate].
enum LegacyEncryptionMode {
  /// Values were stored as plaintext (`EncryptionType.none`).
  none,

  /// Values were XOR-ed with a repeating 512-byte keystream
  /// (`EncryptionType.xor`).
  xor,

  /// Values were encrypted with AES-256-GCM (`EncryptionType.aes256`).
  aes256,
}

/// Decrypts values written by ReaxDB 1.x. Read-only by design.
final class LegacyDecryptor {
  LegacyDecryptor._(this.mode, this._xorKey, this._aesKey);

  /// A decryptor for a plaintext 1.x database; [decrypt] returns its input.
  factory LegacyDecryptor.none() =>
      LegacyDecryptor._(LegacyEncryptionMode.none, null, null);

  /// A decryptor for a 1.x database written with `EncryptionType.xor`.
  ///
  /// [key] is the raw string passed to `ReaxDB.open(..., encryptionKey: ...)`.
  /// Throws [EncryptionException] when [key] is empty.
  factory LegacyDecryptor.xor(String key) {
    if (key.isEmpty) {
      throw const EncryptionException('A ReaxDB 1.x xor key must not be empty');
    }
    return LegacyDecryptor._(LegacyEncryptionMode.xor, expandXorKey(key), null);
  }

  /// A decryptor for a 1.x database written with `EncryptionType.aes256`.
  ///
  /// [key] is the raw string passed to `ReaxDB.open(..., encryptionKey: ...)`.
  /// Throws [EncryptionException] when [key] is empty.
  factory LegacyDecryptor.aes256(String key) {
    if (key.isEmpty) {
      throw const EncryptionException(
        'A ReaxDB 1.x AES-256 key must not be empty',
      );
    }
    return LegacyDecryptor._(
      LegacyEncryptionMode.aes256,
      null,
      deriveAes256Key(key),
    );
  }

  /// Builds the decryptor for [mode], using [key] when the mode needs one.
  ///
  /// Throws [EncryptionException] when [mode] requires a key and [key] is
  /// null or empty.
  factory LegacyDecryptor.forMode(LegacyEncryptionMode mode, String? key) {
    switch (mode) {
      case LegacyEncryptionMode.none:
        return LegacyDecryptor.none();
      case LegacyEncryptionMode.xor:
        if (key == null) {
          throw const EncryptionException(
            'ReaxDB 1.x xor mode requires the original encryption key',
          );
        }
        return LegacyDecryptor.xor(key);
      case LegacyEncryptionMode.aes256:
        if (key == null) {
          throw const EncryptionException(
            'ReaxDB 1.x AES-256 mode requires the original encryption key',
          );
        }
        return LegacyDecryptor.aes256(key);
    }
  }

  /// The 1.x cipher this decryptor undoes.
  final LegacyEncryptionMode mode;

  final Uint8List? _xorKey;
  final Uint8List? _aesKey;

  /// The hardcoded salt ReaxDB 1.x mixed into every AES key derivation.
  static const String aesSalt = 'ReaxDB_Salt_v1_2025';

  /// The number of SHA-256 rounds ReaxDB 1.x performed: one over
  /// `password + salt`, then 10,000 more over the running digest.
  static const int aesRounds = 10001;

  /// Length in bytes of the length-prefixed IV that 1.x wrote in front of
  /// every AES-256-GCM ciphertext.
  static const int aesIvLength = 12;

  /// Length of the expanded XOR keystream used by 1.x.
  static const int xorKeystreamLength = 512;

  /// Reproduces the ReaxDB 1.x AES key derivation.
  ///
  /// `sha256(utf8(password) + utf8(salt))` followed by 10,000 further
  /// `sha256` rounds over the digest. Exposed only so the migrator and its
  /// tests can prove the derivation matches 1.x byte for byte; it must never
  /// be used to protect new data.
  static Uint8List deriveAes256Key(String password) {
    final List<int> salt = utf8.encode(aesSalt);
    final List<int> combined = <int>[...utf8.encode(password), ...salt];
    List<int> digest = sha256.convert(combined).bytes;
    for (int i = 1; i < aesRounds; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return Uint8List.fromList(digest);
  }

  /// Reproduces the ReaxDB 1.x XOR keystream expansion.
  ///
  /// 1.x used `key.codeUnits` (UTF-16 code units truncated to bytes by
  /// [Uint8List.fromList]), repeated until 512 bytes are filled.
  static Uint8List expandXorKey(String key) {
    final Uint8List keyBytes = Uint8List.fromList(key.codeUnits);
    final Uint8List expanded = Uint8List(xorKeystreamLength);
    for (int i = 0; i < xorKeystreamLength; i++) {
      expanded[i] = keyBytes[i % keyBytes.length];
    }
    return expanded;
  }

  /// Returns the plaintext bytes 1.x stored for [stored].
  ///
  /// Throws [EncryptionException] when the record cannot be decrypted, which
  /// for AES-256-GCM includes an authentication tag mismatch (a wrong key or
  /// a tampered record).
  Uint8List decrypt(Uint8List stored) {
    switch (mode) {
      case LegacyEncryptionMode.none:
        return stored;
      case LegacyEncryptionMode.xor:
        return _xorDecrypt(stored);
      case LegacyEncryptionMode.aes256:
        return _aesDecrypt(stored);
    }
  }

  Uint8List _xorDecrypt(Uint8List data) {
    final Uint8List key = _xorKey!;
    final Uint8List out = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      out[i] = data[i] ^ key[i % key.length];
    }
    return out;
  }

  Uint8List _aesDecrypt(Uint8List data) {
    if (data.length < aesIvLength) {
      throw EncryptionException(
        'ReaxDB 1.x AES record is ${data.length} bytes, shorter than the '
        '$aesIvLength byte IV prefix',
      );
    }
    final Uint8List iv = Uint8List.sublistView(data, 0, aesIvLength);
    final Uint8List body = Uint8List.sublistView(data, aesIvLength);
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      false,
      AEADParameters(KeyParameter(_aesKey!), 128, iv, Uint8List(0)),
    );
    try {
      return cipher.process(body);
    } on Object catch (error) {
      throw EncryptionException(
        'ReaxDB 1.x AES-256-GCM record failed to decrypt; the legacy '
        'encryption key is wrong or the record is damaged',
        cause: error,
      );
    }
  }
}
