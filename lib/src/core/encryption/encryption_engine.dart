import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../errors/exceptions.dart';
import 'encryption_config.dart';
import 'encryption_type.dart';
import 'key_derivation.dart';

/// Encrypts and decrypts database values according to an [EncryptionConfig].
///
/// ## Ciphertext envelope (version 1)
///
/// Every non-plaintext value is wrapped in a self-describing envelope so the
/// algorithm of stored data is always detectable and future format changes
/// remain decryptable:
///
/// ```text
/// byte 0        envelope version (0x01)
/// byte 1        algorithm id (0x01 = XOR obfuscation, 0x02 = AES-256-GCM)
/// AES-256-GCM:  bytes 2..13  random 96-bit IV (Random.secure())
///               bytes 14..   ciphertext || 16-byte GCM authentication tag
/// obfuscation:  bytes 2..    XOR ciphertext
/// ```
///
/// [EncryptionType.none] performs no transformation and adds no envelope.
///
/// Decryption validates the envelope version and that the stored algorithm
/// matches the configured one, throwing [EncryptionException] otherwise —
/// including on GCM authentication failure (tampering or wrong key). ReaxDB
/// never silently downgrades: if the requested cipher cannot run, engine
/// construction throws instead of substituting a weaker algorithm.
///
/// Key material (keys, passphrases, derived keys) is never logged.
final class EncryptionEngine {
  /// Current envelope format version.
  static const int envelopeVersion = 0x01;

  /// Envelope algorithm id for XOR obfuscation.
  static const int algorithmIdObfuscation = 0x01;

  /// Envelope algorithm id for AES-256-GCM.
  static const int algorithmIdAes256Gcm = 0x02;

  static const int _headerLength = 2;
  static const int _ivLength = 12;
  static const int _tagLength = 16;
  static const int _expandedXorKeyLength = 512;

  final EncryptionType _type;
  final Uint8List? _expandedXorKey;
  final KeyParameter? _aesKeyParameter;
  final GCMBlockCipher? _gcm;
  final Random _random = Random.secure();

  static final Uint8List _emptyAad = Uint8List(0);

  EncryptionEngine._(
    this._type,
    this._expandedXorKey,
    this._aesKeyParameter,
    this._gcm,
  );

  /// Creates an engine for [config].
  ///
  /// For [EncryptionConfig.aes256FromPassphrase], [kdfSalt] is required: it is
  /// the per-database random salt generated with [KeyDerivation.generateSalt]
  /// on first open and persisted in the database metadata. Passing the same
  /// salt and passphrase always derives the same key.
  ///
  /// Throws [EncryptionException] on invalid key material or a missing salt.
  factory EncryptionEngine(EncryptionConfig config, {Uint8List? kdfSalt}) {
    switch (config) {
      case NoEncryptionConfig():
        return EncryptionEngine._(EncryptionType.none, null, null, null);
      case ObfuscationConfig(:final Uint8List key):
        return EncryptionEngine._(
          EncryptionType.obfuscation,
          _expandXorKey(key),
          null,
          null,
        );
      case Aes256KeyConfig(:final Uint8List key):
        return EncryptionEngine._forAesKey(key);
      case Aes256PassphraseConfig(
        :final String passphrase,
        :final int iterations,
      ):
        if (kdfSalt == null) {
          throw const EncryptionException(
            'A per-database KDF salt is required for passphrase-based '
            'encryption. Generate one with KeyDerivation.generateSalt() on '
            'first open and persist it in the database metadata.',
          );
        }
        final Uint8List key = KeyDerivation.deriveKey(
          passphrase: passphrase,
          salt: kdfSalt,
          iterations: iterations,
        );
        return EncryptionEngine._forAesKey(key);
    }
  }

  factory EncryptionEngine._forAesKey(Uint8List key) {
    if (key.length != KeyDerivation.keyLength) {
      throw EncryptionException(
        'AES-256 requires a ${KeyDerivation.keyLength}-byte key '
        '(got ${key.length} bytes)',
      );
    }
    final GCMBlockCipher gcm;
    try {
      gcm = GCMBlockCipher(AESEngine());
    } catch (e) {
      // Never downgrade to a weaker cipher: fail loudly instead.
      throw EncryptionException(
        'AES-256-GCM is not available on this platform',
        cause: e,
      );
    }
    return EncryptionEngine._(
      EncryptionType.aes256,
      null,
      KeyParameter(Uint8List.fromList(key)),
      gcm,
    );
  }

  /// The effective algorithm this engine applies.
  EncryptionType get type => _type;

  /// Encrypts [data], returning the enveloped ciphertext.
  ///
  /// For [EncryptionType.none] returns [data] unchanged.
  Uint8List encrypt(Uint8List data) {
    switch (_type) {
      case EncryptionType.none:
        return data;
      case EncryptionType.obfuscation:
        return _obfuscate(data);
      case EncryptionType.aes256:
        return _encryptAes256(data);
    }
  }

  /// Decrypts enveloped [data], validating the envelope and, for AES-256-GCM,
  /// the authentication tag.
  ///
  /// Accepts sublist views: the input's `offsetInBytes` is respected.
  /// Throws [EncryptionException] on an unknown envelope version, an
  /// algorithm mismatch, truncated input, or authentication failure
  /// (tampered data or wrong key).
  Uint8List decrypt(Uint8List data) {
    if (_type == EncryptionType.none) {
      return data;
    }
    if (data.length < _headerLength) {
      throw EncryptionException(
        'Encrypted value too short (${data.length} bytes)',
      );
    }
    final int version = data[0];
    if (version != envelopeVersion) {
      throw EncryptionException(
        'Unsupported ciphertext envelope version $version '
        '(supported: $envelopeVersion)',
      );
    }
    final int algorithm = data[1];
    final int expected =
        _type == EncryptionType.aes256
            ? algorithmIdAes256Gcm
            : algorithmIdObfuscation;
    if (algorithm != expected) {
      throw EncryptionException(
        'Stored value uses algorithm id $algorithm but the database is '
        'configured for ${_type.name} (algorithm id $expected)',
      );
    }
    return _type == EncryptionType.aes256
        ? _decryptAes256(data)
        : _deobfuscate(data);
  }

  /// Returns metadata describing the EFFECTIVE encryption configuration.
  ///
  /// The reported algorithm and security level always describe what this
  /// engine actually does — never an aspirational or requested value.
  Map<String, dynamic> getMetadata() {
    return <String, dynamic>{
      'enabled': _type != EncryptionType.none,
      'type': _type.name,
      'display_name': _type.displayName,
      'security_level': _type.securityLevel,
      'performance_impact': _type.performanceImpact,
      'is_authenticated': _type == EncryptionType.aes256,
      'is_secure': _type == EncryptionType.aes256,
      'envelope_version': envelopeVersion,
    };
  }

  // --- AES-256-GCM -----------------------------------------------------

  Uint8List _encryptAes256(Uint8List data) {
    final GCMBlockCipher gcm = _gcm!;
    final Uint8List result = Uint8List(
      _headerLength + _ivLength + data.length + _tagLength,
    );
    result[0] = envelopeVersion;
    result[1] = algorithmIdAes256Gcm;
    for (int i = 0; i < _ivLength; i++) {
      result[_headerLength + i] = _random.nextInt(256);
    }
    final Uint8List iv = Uint8List.sublistView(
      result,
      _headerLength,
      _headerLength + _ivLength,
    );
    gcm.init(
      true,
      AEADParameters(_aesKeyParameter!, _tagLength * 8, iv, _emptyAad),
    );
    const int ctOffset = _headerLength + _ivLength;
    int written = gcm.processBytes(data, 0, data.length, result, ctOffset);
    try {
      written += gcm.doFinal(result, ctOffset + written);
    } catch (e) {
      throw EncryptionException('AES-256-GCM encryption failed', cause: e);
    }
    if (ctOffset + written == result.length) {
      return result;
    }
    return Uint8List.sublistView(result, 0, ctOffset + written);
  }

  Uint8List _decryptAes256(Uint8List data) {
    const int ctOffset = _headerLength + _ivLength;
    if (data.length < ctOffset + _tagLength) {
      throw EncryptionException(
        'Encrypted value too short for AES-256-GCM (${data.length} bytes)',
      );
    }
    final GCMBlockCipher gcm = _gcm!;
    // sublistView respects offsetInBytes, unlike Uint8List.view(data.buffer).
    final Uint8List iv = Uint8List.sublistView(data, _headerLength, ctOffset);
    final Uint8List ciphertext = Uint8List.sublistView(data, ctOffset);
    gcm.init(
      false,
      AEADParameters(_aesKeyParameter!, _tagLength * 8, iv, _emptyAad),
    );
    final Uint8List out = Uint8List(gcm.getOutputSize(ciphertext.length));
    int written = gcm.processBytes(ciphertext, 0, ciphertext.length, out, 0);
    try {
      written += gcm.doFinal(out, written);
    } catch (e) {
      throw EncryptionException(
        'AES-256-GCM authentication failed: the data was tampered with or '
        'the key is wrong',
        cause: e,
      );
    }
    if (written == out.length) {
      return out;
    }
    return Uint8List.sublistView(out, 0, written);
  }

  // --- XOR obfuscation (NOT encryption) --------------------------------

  Uint8List _obfuscate(Uint8List data) {
    final Uint8List key = _expandedXorKey!;
    final int keyLen = key.length;
    final Uint8List result = Uint8List(_headerLength + data.length);
    result[0] = envelopeVersion;
    result[1] = algorithmIdObfuscation;
    for (int i = 0; i < data.length; i++) {
      result[_headerLength + i] = data[i] ^ key[i % keyLen];
    }
    return result;
  }

  Uint8List _deobfuscate(Uint8List data) {
    final Uint8List key = _expandedXorKey!;
    final int keyLen = key.length;
    final int length = data.length - _headerLength;
    final Uint8List result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = data[_headerLength + i] ^ key[i % keyLen];
    }
    return result;
  }

  static Uint8List _expandXorKey(Uint8List key) {
    final Uint8List expanded = Uint8List(_expandedXorKeyLength);
    final int keyLen = key.length;
    for (int i = 0; i < _expandedXorKeyLength; i++) {
      expanded[i] = key[i % keyLen];
    }
    return expanded;
  }
}
