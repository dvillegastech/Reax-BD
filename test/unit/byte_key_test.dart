import 'dart:typed_data';

import 'package:reaxdb_dart/src/core/util/byte_key.dart';
import 'package:test/test.dart';

void main() {
  group('ByteKey', () {
    test('equality is by content, not identity', () {
      final a = ByteKey(Uint8List.fromList([1, 2, 3]));
      final b = ByteKey(Uint8List.fromList([1, 2, 3]));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(ByteKey(Uint8List.fromList([1, 2, 4])))));
    });

    test('works as a Map key', () {
      final map = <ByteKey, int>{};
      map[ByteKey.fromString('user:1')] = 1;
      map[ByteKey.fromString('user:1')] = 2;
      expect(map.length, 1);
      expect(map[ByteKey.fromString('user:1')], 2);
    });

    test('fromString uses UTF-8, not code units', () {
      final key = ByteKey.fromString('ñandú 🦤');
      expect(key.asString, 'ñandú 🦤');
      // Multi-byte characters must expand beyond their rune count.
      expect(key.bytes.length, greaterThan('ñandú 🦤'.length));
    });

    test('long keys with equal XOR folds do not collide', () {
      // These two 40-byte keys have identical XOR folds of their bytes,
      // which corrupted the old memtable cache.
      final a = Uint8List.fromList(List.generate(40, (i) => i % 7));
      final b = Uint8List.fromList(List.generate(40, (i) => (39 - i) % 7));
      expect(ByteKey(a), isNot(equals(ByteKey(b))));
    });

    test('compareTo is lexicographic by unsigned byte', () {
      final low = ByteKey(Uint8List.fromList([1, 2]));
      final high = ByteKey(Uint8List.fromList([1, 2, 0]));
      final higher = ByteKey(Uint8List.fromList([1, 0xff]));
      expect(low.compareTo(high), lessThan(0));
      expect(high.compareTo(low), greaterThan(0));
      expect(low.compareTo(higher), lessThan(0));
      expect(low.compareTo(ByteKey(Uint8List.fromList([1, 2]))), 0);
    });
  });
}
