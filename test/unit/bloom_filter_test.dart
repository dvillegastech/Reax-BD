import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:reaxdb_dart/src/core/errors/exceptions.dart';
import 'package:reaxdb_dart/src/core/storage/bloom_filter.dart';
import 'package:test/test.dart';

Uint8List _key(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('BloomFilter', () {
    test('never produces false negatives', () {
      final filter = BloomFilter(expectedEntries: 1000);
      for (var i = 0; i < 1000; i++) {
        filter.add(_key('key-$i'));
      }
      for (var i = 0; i < 1000; i++) {
        expect(filter.mightContain(_key('key-$i')), isTrue);
      }
    });

    test('false positive rate stays near the configured target', () {
      final filter = BloomFilter(
        expectedEntries: 2000,
        falsePositiveRate: 0.01,
      );
      for (var i = 0; i < 2000; i++) {
        filter.add(_key('member-$i'));
      }
      var falsePositives = 0;
      for (var i = 0; i < 10000; i++) {
        if (filter.mightContain(_key('absent-$i'))) falsePositives++;
      }
      expect(falsePositives / 10000, lessThan(0.05));
    });

    test('serialization round-trips', () {
      final rng = Random(7);
      final filter = BloomFilter(expectedEntries: 500);
      final keys = [
        for (var i = 0; i < 500; i++)
          Uint8List.fromList(
            List.generate(1 + rng.nextInt(64), (_) => rng.nextInt(256)),
          ),
      ];
      for (final k in keys) {
        filter.add(k);
      }
      final restored = BloomFilter.fromBytes(filter.toBytes());
      expect(restored.hashCount, filter.hashCount);
      expect(restored.bitCount, filter.bitCount);
      for (final k in keys) {
        expect(restored.mightContain(k), isTrue);
      }
    });

    test('rejects a malformed serialized filter', () {
      expect(
        () => BloomFilter.fromBytes(Uint8List.fromList([99, 0, 0])),
        throwsA(isA<CorruptionException>()),
      );
    });
  });
}
