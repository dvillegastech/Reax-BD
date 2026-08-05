import 'dart:typed_data';

import 'package:reaxdb_dart/src/core/cache/multi_level_cache.dart';
import 'package:test/test.dart';

Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('ReaxCache basics', () {
    test('stores and retrieves values', () {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('one'));
      expect(cache.get('a'), equals(bytes('one')));
      expect(cache.get('missing'), isNull);
    });

    test('overwriting a key replaces value and memory accounting', () {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('short'));
      final int before = cache.memoryBytes;
      cache.put('a', bytes('a much longer value than before'));
      expect(cache.length, equals(1));
      expect(cache.memoryBytes, greaterThan(before));
      cache.remove('a');
      expect(cache.memoryBytes, equals(0));
    });

    test('remove and clear', () {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('1'));
      cache.put('b', bytes('2'));
      cache.remove('a');
      expect(cache.get('a'), isNull);
      cache.clear();
      expect(cache.length, equals(0));
      expect(cache.memoryBytes, equals(0));
    });

    test('containsKey does not touch statistics', () {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('1'));
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('b'), isFalse);
      expect(cache.stats.hits, equals(0));
      expect(cache.stats.misses, equals(0));
    });
  });

  group('eviction', () {
    test('evicts least recently used first', () {
      final ReaxCache cache = ReaxCache(maxEntries: 3);
      cache.put('a', bytes('1'));
      cache.put('b', bytes('2'));
      cache.put('c', bytes('3'));
      cache.get('a'); // refresh 'a'
      cache.put('d', bytes('4')); // evicts 'b'

      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNotNull);
      expect(cache.get('c'), isNotNull);
      expect(cache.get('d'), isNotNull);
      expect(cache.stats.evictions, equals(1));
    });

    test('respects the memory bound', () {
      final ReaxCache cache = ReaxCache(maxEntries: 1000, maxMemoryBytes: 400);
      for (int i = 0; i < 10; i++) {
        cache.put('key$i', Uint8List(64));
      }
      expect(cache.memoryBytes, lessThanOrEqualTo(400));
      expect(cache.length, lessThan(10));
    });

    test('eviction after remove does not crash', () {
      // The old LFU cache could crash evicting from an empty frequency
      // group after remove(); the collapsed cache must stay consistent.
      final ReaxCache cache = ReaxCache(maxEntries: 2);
      cache.put('a', bytes('1'));
      cache.put('b', bytes('2'));
      cache.remove('a');
      cache.put('c', bytes('3'));
      cache.put('d', bytes('4')); // forces eviction
      expect(cache.length, equals(2));
    });
  });

  group('statistics', () {
    test('one logical miss counts exactly once', () {
      // The old multi-level stats counted one miss as three (L1+L2+L3).
      final ReaxCache cache = ReaxCache();
      cache.get('absent');
      expect(cache.stats.misses, equals(1));
      expect(cache.stats.hits, equals(0));
    });

    test('hit ratio reflects logical lookups', () {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('1'));
      cache.get('a'); // hit
      cache.get('b'); // miss
      expect(cache.stats.hits, equals(1));
      expect(cache.stats.misses, equals(1));
      expect(cache.stats.hitRatio, equals(0.5));
    });
  });

  group('TTL', () {
    test('entries expire after their ttl', () async {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('1'), ttl: const Duration(milliseconds: 20));
      expect(cache.get('a'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cache.get('a'), isNull);
      expect(cache.stats.expirations, equals(1));
      expect(cache.length, equals(0));
    });

    test('absolute expiresAt is honored', () async {
      final ReaxCache cache = ReaxCache();
      cache.put(
        'a',
        bytes('1'),
        expiresAt: DateTime.now().add(const Duration(milliseconds: 20)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cache.get('a'), isNull);
    });

    test('default ttl applies when none is given', () async {
      final ReaxCache cache = ReaxCache(
        defaultTtl: const Duration(milliseconds: 20),
      );
      cache.put('a', bytes('1'));
      cache.put('b', bytes('2'), ttl: const Duration(minutes: 5));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNotNull);
    });

    test('removeExpired reclaims expired entries eagerly', () async {
      final ReaxCache cache = ReaxCache();
      cache.put('a', bytes('1'), ttl: const Duration(milliseconds: 10));
      cache.put('b', bytes('2'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cache.removeExpired(), equals(1));
      expect(cache.length, equals(1));
      expect(cache.stats.expirations, equals(1));
    });
  });

  group('invalidation', () {
    test('removePrefix removes only matching keys', () {
      final ReaxCache cache = ReaxCache();
      cache.put('users:1', bytes('a'));
      cache.put('users:2', bytes('b'));
      cache.put('orders:1', bytes('c'));

      cache.removePrefix('users:');
      expect(cache.get('users:1'), isNull);
      expect(cache.get('users:2'), isNull);
      expect(cache.get('orders:1'), isNotNull);
    });

    test('invalidatePattern supports star, prefix-star and exact keys', () {
      final ReaxCache cache = ReaxCache();
      cache.put('users:1', bytes('a'));
      cache.put('orders:1', bytes('b'));

      cache.invalidatePattern('users:*');
      expect(cache.containsKey('users:1'), isFalse);
      expect(cache.containsKey('orders:1'), isTrue);

      cache.invalidatePattern('orders:1');
      expect(cache.containsKey('orders:1'), isFalse);

      cache.put('x', bytes('1'));
      cache.invalidatePattern('*');
      expect(cache.length, equals(0));
    });

    test('regex patterns still work as a fallback', () {
      final ReaxCache cache = ReaxCache();
      cache.put('users:1', bytes('a'));
      cache.put('users:22', bytes('b'));
      cache.put('other', bytes('c'));

      cache.invalidatePattern(r'users:\d$');
      expect(cache.containsKey('users:1'), isFalse);
      expect(cache.containsKey('users:22'), isTrue);
      expect(cache.containsKey('other'), isTrue);
    });
  });

  group('construction', () {
    test('rejects non-positive bounds', () {
      expect(() => ReaxCache(maxEntries: 0), throwsArgumentError);
      expect(() => ReaxCache(maxMemoryBytes: 0), throwsArgumentError);
    });
  });
}
