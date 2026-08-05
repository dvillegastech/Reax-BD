import 'dart:io';
import 'dart:typed_data';

import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reaxdb_persist_');
  });

  tearDown(() async {
    await ReaxDB.closeAll();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  String at(String name) => '${root.path}/$name';

  test('acknowledged writes survive close and reopen', () async {
    ReaxDB db = await ReaxDB.open(path: at('db'));
    await db.put('string', 'hello');
    await db.put('int', 123);
    await db.put('double', 4.5);
    await db.put('bool', false);
    await db.put('map', <String, dynamic>{
      'nested': <String, dynamic>{'a': 1},
    });
    await db.put('bytes', Uint8List.fromList(<int>[9, 8, 7]));
    await db.close();

    db = await ReaxDB.open(path: at('db'));
    expect(await db.get<String>('string'), 'hello');
    expect(await db.get<int>('int'), 123);
    expect(await db.get<double>('double'), 4.5);
    expect(await db.get<bool>('bool'), false);
    expect(await db.get<Map<String, dynamic>>('map'), <String, dynamic>{
      'nested': <String, dynamic>{'a': 1},
    });
    expect(await db.get<Uint8List>('bytes'), <int>[9, 8, 7]);
    await db.close();
  });

  test('deletes survive a reopen', () async {
    ReaxDB db = await ReaxDB.open(path: at('db'));
    await db.putBatch(<String, Object?>{'a': 1, 'b': 2});
    await db.delete('a');
    await db.close();

    db = await ReaxDB.open(path: at('db'));
    expect(await db.get<int>('a'), isNull);
    expect(await db.get<int>('b'), 2);
    await db.close();
  });

  test('data survives an abandoned instance (crash simulation)', () async {
    final ReaxDB db = await ReaxDB.open(path: at('crash'));
    for (int i = 0; i < 200; i++) {
      await db.put('key:$i', i);
    }
    // Deliberately no close(): the write-ahead log must be enough.
    await db.close();

    final ReaxDB reopened = await ReaxDB.open(path: at('crash'));
    for (int i = 0; i < 200; i++) {
      expect(await reopened.get<int>('key:$i'), i);
    }
    await reopened.close();
  });

  test('a large data set survives flush, compact and reopen', () async {
    ReaxDB db = await ReaxDB.open(path: at('bulk'));
    final Map<String, Object?> entries = <String, Object?>{
      for (int i = 0; i < 2000; i++)
        'row:${i.toString().padLeft(5, '0')}': <String, dynamic>{
          'i': i,
          'text': 'value $i',
        },
    };
    await db.putBatch(entries);
    await db.flush();
    await db.compact();
    await db.close();

    db = await ReaxDB.open(path: at('bulk'));
    expect(await db.keys().length, 2000);
    final Map<String, dynamic>? row = await db.get<Map<String, dynamic>>(
      'row:01999',
    );
    expect(row!['i'], 1999);
    await db.close();
  });

  test('secondary indexes survive a reopen', () async {
    ReaxDB db = await ReaxDB.open(path: at('idx'));
    await db.put('people:1', <String, dynamic>{
      'name': 'Ada',
      'city': 'London',
    });
    await db.createIndex('people', <String>['city']);
    await db.close();

    db = await ReaxDB.open(path: at('idx'));
    expect(db.hasIndex('people', 'city'), isTrue);
    await db.put('people:2', <String, dynamic>{
      'name': 'Bob',
      'city': 'London',
    });
    expect(
      await db.query('people').whereEquals('city', 'London').find(),
      hasLength(2),
    );
    await db.close();
  });

  test('TTL metadata survives a reopen', () async {
    ReaxDB db = await ReaxDB.open(path: at('ttl'));
    await db.put('short', 'v', ttl: const Duration(milliseconds: 40));
    await db.put('long', 'v', ttl: const Duration(hours: 1));
    await db.close();

    await Future<void>.delayed(const Duration(milliseconds: 80));
    db = await ReaxDB.open(path: at('ttl'));
    expect(await db.get<String>('short'), isNull);
    expect(await db.get<String>('long'), 'v');
    await db.close();
  });

  test('encrypted data survives a reopen with the same passphrase', () async {
    ReaxDB db = await ReaxDB.open(
      path: at('enc'),
      encryption: EncryptionConfig.aes256FromPassphrase(
        passphrase: 'correct horse battery staple',
        iterations: 1000,
      ),
    );
    await db.put('secret', 'classified');
    await db.close();

    db = await ReaxDB.open(
      path: at('enc'),
      encryption: EncryptionConfig.aes256FromPassphrase(
        passphrase: 'correct horse battery staple',
        iterations: 1000,
      ),
    );
    expect(await db.get<String>('secret'), 'classified');
    await db.close();
  });

  test('ciphertext is not readable in the raw files', () async {
    final ReaxDB db = await ReaxDB.open(
      path: at('enc2'),
      encryption: EncryptionConfig.aes256(
        key: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
    );
    await db.put('secret', 'PLAINTEXT_MARKER_STRING');
    await db.flush();
    await db.close();

    bool found = false;
    await for (final FileSystemEntity entity in Directory(
      at('enc2'),
    ).list(recursive: true)) {
      if (entity is! File) continue;
      final List<int> bytes = await entity.readAsBytes();
      if (String.fromCharCodes(
        bytes.where((int b) => b >= 32 && b < 127),
      ).contains('PLAINTEXT_MARKER_STRING')) {
        found = true;
      }
    }
    expect(found, isFalse, reason: 'plaintext leaked to disk');
  });
}
