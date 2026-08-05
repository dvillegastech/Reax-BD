/// Bloom filter used by SSTables to skip files that cannot contain a key.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../errors/exceptions.dart';

/// Space-efficient probabilistic set membership filter.
///
/// False positives are possible; false negatives are not. Hashing uses
/// double hashing over two 64-bit FNV-1a variants.
final class BloomFilter {
  BloomFilter._(this._bits, this.hashCount);

  /// Creates a filter sized for [expectedEntries] at roughly
  /// [falsePositiveRate].
  factory BloomFilter({
    required int expectedEntries,
    double falsePositiveRate = 0.01,
  }) {
    final n = expectedEntries < 1 ? 1 : expectedEntries;
    final ln2 = math.ln2;
    final m = (-n * math.log(falsePositiveRate) / (ln2 * ln2)).ceil();
    final bitCount = m < 64 ? 64 : m;
    var k = (bitCount / n * ln2).round();
    if (k < 1) k = 1;
    if (k > 16) k = 16;
    return BloomFilter._(Uint8List((bitCount + 7) >> 3), k);
  }

  /// Restores a filter produced by [toBytes].
  factory BloomFilter.fromBytes(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] < 1 || bytes[0] > 16) {
      throw const CorruptionException('Malformed bloom filter block');
    }
    return BloomFilter._(
      Uint8List.fromList(Uint8List.sublistView(bytes, 1)),
      bytes[0],
    );
  }

  /// Number of hash probes per key.
  final int hashCount;

  final Uint8List _bits;

  /// Number of bits in the filter.
  int get bitCount => _bits.length << 3;

  static const int _fnvPrime = 0x100000001b3;

  static int _hash(Uint8List bytes, int seed) {
    var h = 0xcbf29ce484222325 ^ seed;
    for (var i = 0; i < bytes.length; i++) {
      h ^= bytes[i];
      h = (h * _fnvPrime) & 0x7fffffffffffffff;
    }
    return h;
  }

  /// Inserts [key] into the filter.
  void add(Uint8List key) {
    final h1 = _hash(key, 0);
    final h2 = _hash(key, 0x5bd1e995) | 1;
    final m = bitCount;
    for (var i = 0; i < hashCount; i++) {
      final bit = ((h1 + i * h2) & 0x7fffffffffffffff) % m;
      _bits[bit >> 3] |= 1 << (bit & 7);
    }
  }

  /// Returns false when [key] is definitely absent; true when it may be
  /// present.
  bool mightContain(Uint8List key) {
    final h1 = _hash(key, 0);
    final h2 = _hash(key, 0x5bd1e995) | 1;
    final m = bitCount;
    for (var i = 0; i < hashCount; i++) {
      final bit = ((h1 + i * h2) & 0x7fffffffffffffff) % m;
      if (_bits[bit >> 3] & (1 << (bit & 7)) == 0) return false;
    }
    return true;
  }

  /// Serializes the filter as `[hashCount u8][bit bytes]`.
  Uint8List toBytes() {
    final out = Uint8List(1 + _bits.length);
    out[0] = hashCount;
    out.setRange(1, out.length, _bits);
    return out;
  }
}
