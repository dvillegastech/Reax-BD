import 'dart:convert';
import 'dart:typed_data';

import 'package:reaxdb_dart/src/core/encryption/encryption_config.dart';
import 'package:reaxdb_dart/src/core/encryption/encryption_engine.dart';
import 'package:reaxdb_dart/src/core/encryption/key_derivation.dart';
import 'package:reaxdb_dart/src/core/errors/exceptions.dart';
import 'package:test/test.dart';

void main() {
  final Uint8List rawKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final Uint8List salt = Uint8List.fromList(
    List<int>.generate(16, (i) => 200 - i),
  );
  final Uint8List plaintext = Uint8List.fromList(
    utf8.encode('The quick brown fox jumps over the lazy dog'),
  );

  EncryptionEngine aesEngine() =>
      EncryptionEngine(EncryptionConfig.aes256(key: rawKey));

  group('EncryptionConfig', () {
    test('aes256 rejects keys that are not 32 bytes', () {
      expect(
        () => EncryptionConfig.aes256(key: Uint8List(16)),
        throwsA(isA<EncryptionException>()),
      );
      expect(
        () => EncryptionConfig.aes256(key: Uint8List(33)),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('passphrase config rejects empty passphrase and low iterations', () {
      expect(
        () => EncryptionConfig.aes256FromPassphrase(passphrase: ''),
        throwsA(isA<EncryptionException>()),
      );
      expect(
        () => EncryptionConfig.aes256FromPassphrase(
          passphrase: 'secret',
          iterations: 10,
        ),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('obfuscation rejects empty key', () {
      expect(
        () => EncryptionConfig.obfuscation(key: Uint8List(0)),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('toString never contains key material', () {
      expect(
        EncryptionConfig.aes256(key: rawKey).toString(),
        'EncryptionConfig(aes256)',
      );
      final EncryptionConfig pass = EncryptionConfig.aes256FromPassphrase(
        passphrase: 'hunter2-passphrase',
        iterations: KeyDerivation.minIterations,
      );
      expect(pass.toString(), isNot(contains('hunter2')));
    });
  });

  group('round-trips', () {
    test('none mode is a pass-through', () {
      final EncryptionEngine engine = EncryptionEngine(
        const EncryptionConfig.none(),
      );
      expect(engine.encrypt(plaintext), same(plaintext));
      expect(engine.decrypt(plaintext), same(plaintext));
    });

    test('aes256 with raw key round-trips', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List ciphertext = engine.encrypt(plaintext);
      expect(ciphertext, isNot(equals(plaintext)));
      expect(engine.decrypt(ciphertext), equals(plaintext));
    });

    test('aes256 from passphrase round-trips across engine instances', () {
      final EncryptionConfig config = EncryptionConfig.aes256FromPassphrase(
        passphrase: 'correct horse battery staple',
        iterations: KeyDerivation.minIterations,
      );
      final Uint8List ciphertext = EncryptionEngine(
        config,
        kdfSalt: salt,
      ).encrypt(plaintext);
      final Uint8List decrypted = EncryptionEngine(
        config,
        kdfSalt: salt,
      ).decrypt(ciphertext);
      expect(decrypted, equals(plaintext));
    });

    test('obfuscation round-trips', () {
      final EncryptionConfig config = EncryptionConfig.obfuscation(
        key: Uint8List.fromList(utf8.encode('obf-key')),
      );
      final EncryptionEngine engine = EncryptionEngine(config);
      final Uint8List ciphertext = engine.encrypt(plaintext);
      expect(ciphertext, isNot(equals(plaintext)));
      expect(engine.decrypt(ciphertext), equals(plaintext));
    });

    test('aes256 round-trips empty and large payloads', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List empty = Uint8List(0);
      expect(engine.decrypt(engine.encrypt(empty)), equals(empty));
      final Uint8List large = Uint8List.fromList(
        List<int>.generate(100000, (i) => (i * 31) & 0xFF),
      );
      expect(engine.decrypt(engine.encrypt(large)), equals(large));
    });
  });

  group('IV randomness', () {
    test('same plaintext encrypts to different ciphertext on each call', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List a = engine.encrypt(plaintext);
      final Uint8List b = engine.encrypt(plaintext);
      expect(a, isNot(equals(b)));
      // Specifically the IVs (bytes 2..13) must differ.
      expect(a.sublist(2, 14), isNot(equals(b.sublist(2, 14))));
    });
  });

  group('authentication', () {
    test('tampering with any single ciphertext byte throws', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List ciphertext = engine.encrypt(plaintext);
      // Flip a byte in the IV, the body, and the tag region.
      for (final int index in <int>[2, 14, ciphertext.length - 1]) {
        final Uint8List tampered = Uint8List.fromList(ciphertext);
        tampered[index] ^= 0x01;
        expect(
          () => engine.decrypt(tampered),
          throwsA(isA<EncryptionException>()),
          reason: 'tampered byte $index must fail authentication',
        );
      }
    });

    test('wrong raw key throws EncryptionException, never garbage', () {
      final Uint8List ciphertext = aesEngine().encrypt(plaintext);
      final Uint8List otherKey = Uint8List.fromList(
        List<int>.generate(32, (i) => 255 - i),
      );
      final EncryptionEngine wrong = EncryptionEngine(
        EncryptionConfig.aes256(key: otherKey),
      );
      expect(
        () => wrong.decrypt(ciphertext),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('wrong passphrase throws EncryptionException', () {
      final Uint8List ciphertext = EncryptionEngine(
        EncryptionConfig.aes256FromPassphrase(
          passphrase: 'right passphrase',
          iterations: KeyDerivation.minIterations,
        ),
        kdfSalt: salt,
      ).encrypt(plaintext);
      final EncryptionEngine wrong = EncryptionEngine(
        EncryptionConfig.aes256FromPassphrase(
          passphrase: 'wrong passphrase',
          iterations: KeyDerivation.minIterations,
        ),
        kdfSalt: salt,
      );
      expect(
        () => wrong.decrypt(ciphertext),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  group('KeyDerivation', () {
    test('is deterministic for same passphrase, salt and iterations', () {
      final Uint8List a = KeyDerivation.deriveKey(
        passphrase: 'p@ss',
        salt: salt,
        iterations: KeyDerivation.minIterations,
      );
      final Uint8List b = KeyDerivation.deriveKey(
        passphrase: 'p@ss',
        salt: salt,
        iterations: KeyDerivation.minIterations,
      );
      expect(a, equals(b));
      expect(a.length, KeyDerivation.keyLength);
    });

    test('differs across salts, passphrases and iteration counts', () {
      final Uint8List base = KeyDerivation.deriveKey(
        passphrase: 'p@ss',
        salt: salt,
        iterations: KeyDerivation.minIterations,
      );
      final Uint8List otherSalt = KeyDerivation.deriveKey(
        passphrase: 'p@ss',
        salt: KeyDerivation.generateSalt(),
        iterations: KeyDerivation.minIterations,
      );
      final Uint8List otherPass = KeyDerivation.deriveKey(
        passphrase: 'p@ss2',
        salt: salt,
        iterations: KeyDerivation.minIterations,
      );
      final Uint8List otherIters = KeyDerivation.deriveKey(
        passphrase: 'p@ss',
        salt: salt,
        iterations: KeyDerivation.minIterations + 1,
      );
      expect(base, isNot(equals(otherSalt)));
      expect(base, isNot(equals(otherPass)));
      expect(base, isNot(equals(otherIters)));
    });

    test('generateSalt produces distinct random salts', () {
      final Uint8List a = KeyDerivation.generateSalt();
      final Uint8List b = KeyDerivation.generateSalt();
      expect(a.length, KeyDerivation.saltLength);
      expect(a, isNot(equals(b)));
    });

    test('rejects tiny salts and iteration counts', () {
      expect(
        () => KeyDerivation.deriveKey(passphrase: 'p', salt: Uint8List(4)),
        throwsA(isA<EncryptionException>()),
      );
      expect(
        () =>
            KeyDerivation.deriveKey(passphrase: 'p', salt: salt, iterations: 1),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('passphrase engine requires a salt', () {
      expect(
        () => EncryptionEngine(
          EncryptionConfig.aes256FromPassphrase(
            passphrase: 'secret',
            iterations: KeyDerivation.minIterations,
          ),
        ),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  group('sublist views (offsetInBytes)', () {
    test('aes256 decrypt works when input is a view with nonzero offset', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List ciphertext = engine.encrypt(plaintext);
      // Embed the ciphertext mid-buffer and hand decrypt a view into it.
      final Uint8List buffer = Uint8List(ciphertext.length + 64);
      buffer.setRange(37, 37 + ciphertext.length, ciphertext);
      final Uint8List view = Uint8List.sublistView(
        buffer,
        37,
        37 + ciphertext.length,
      );
      expect(view.offsetInBytes, isNonZero);
      expect(engine.decrypt(view), equals(plaintext));
    });

    test('obfuscation decrypt works on an offset view', () {
      final EncryptionEngine engine = EncryptionEngine(
        EncryptionConfig.obfuscation(
          key: Uint8List.fromList(utf8.encode('k1')),
        ),
      );
      final Uint8List ciphertext = engine.encrypt(plaintext);
      final Uint8List buffer = Uint8List(ciphertext.length + 10);
      buffer.setRange(5, 5 + ciphertext.length, ciphertext);
      final Uint8List view = Uint8List.sublistView(
        buffer,
        5,
        5 + ciphertext.length,
      );
      expect(engine.decrypt(view), equals(plaintext));
    });
  });

  group('envelope validation', () {
    test('unknown envelope version throws', () {
      final EncryptionEngine engine = aesEngine();
      final Uint8List ciphertext = engine.encrypt(plaintext);
      final Uint8List badVersion = Uint8List.fromList(ciphertext);
      badVersion[0] = 0x7F;
      expect(
        () => engine.decrypt(badVersion),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('algorithm mismatch throws', () {
      final EncryptionEngine obf = EncryptionEngine(
        EncryptionConfig.obfuscation(
          key: Uint8List.fromList(utf8.encode('k1')),
        ),
      );
      final Uint8List obfData = obf.encrypt(plaintext);
      expect(
        () => aesEngine().decrypt(obfData),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('truncated ciphertext throws', () {
      final EncryptionEngine engine = aesEngine();
      expect(
        () => engine.decrypt(Uint8List(1)),
        throwsA(isA<EncryptionException>()),
      );
      expect(
        () => engine.decrypt(
          Uint8List.fromList(<int>[
            EncryptionEngine.envelopeVersion,
            EncryptionEngine.algorithmIdAes256Gcm,
            1,
            2,
          ]),
        ),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('envelope layout: version, algorithm id, IV, tag present', () {
      final Uint8List ciphertext = aesEngine().encrypt(plaintext);
      expect(ciphertext[0], EncryptionEngine.envelopeVersion);
      expect(ciphertext[1], EncryptionEngine.algorithmIdAes256Gcm);
      // header(2) + iv(12) + plaintext + tag(16)
      expect(ciphertext.length, 2 + 12 + plaintext.length + 16);
    });
  });

  group('metadata honesty', () {
    test('aes256 reports high security and authentication', () {
      final Map<String, dynamic> meta = aesEngine().getMetadata();
      expect(meta['type'], 'aes256');
      expect(meta['is_secure'], isTrue);
      expect(meta['is_authenticated'], isTrue);
      expect(
        (meta['security_level'] as String).toLowerCase(),
        contains('high'),
      );
    });

    test('obfuscation reports it is not secure', () {
      final Map<String, dynamic> meta =
          EncryptionEngine(
            EncryptionConfig.obfuscation(
              key: Uint8List.fromList(utf8.encode('k1')),
            ),
          ).getMetadata();
      expect(meta['type'], 'obfuscation');
      expect(meta['is_secure'], isFalse);
      expect(meta['is_authenticated'], isFalse);
      expect(
        (meta['security_level'] as String).toLowerCase(),
        contains('obfuscation'),
      );
      expect(
        (meta['security_level'] as String).toLowerCase(),
        isNot(contains('high')),
      );
    });

    test('none reports disabled', () {
      final Map<String, dynamic> meta =
          EncryptionEngine(const EncryptionConfig.none()).getMetadata();
      expect(meta['enabled'], isFalse);
      expect(meta['is_secure'], isFalse);
    });
  });
}
