/// Value-equality wrapper for binary keys.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Value-equality wrapper for binary keys. Use as a Map/Set key.
///
/// Dart's `List<int>` uses identity equality, so raw byte lists must never be
/// used directly as map keys. [ByteKey] compares and hashes by content and
/// orders lexicographically by unsigned byte value.
final class ByteKey implements Comparable<ByteKey> {
  /// Wraps [bytes]. The list is not copied; callers must not mutate it.
  ByteKey(this.bytes) : hashCode = _computeHash(bytes);

  /// Creates a key from the UTF-8 encoding of [s].
  factory ByteKey.fromString(String s) =>
      ByteKey(Uint8List.fromList(utf8.encode(s)));

  /// The raw key bytes.
  final Uint8List bytes;

  /// Content hash, computed once at construction (FNV-1a).
  @override
  final int hashCode;

  /// Decodes the key bytes as UTF-8.
  String get asString => utf8.decode(bytes);

  static int _computeHash(Uint8List bytes) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < bytes.length; i++) {
      hash ^= bytes[i];
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ByteKey) return false;
    if (other.hashCode != hashCode) return false;
    final a = bytes;
    final b = other.bytes;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int compareTo(ByteKey other) => compareBytes(bytes, other.bytes);

  /// Lexicographic unsigned comparison of two byte sequences.
  static int compareBytes(Uint8List a, Uint8List b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  @override
  String toString() => 'ByteKey(${_hex(bytes)})';

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final v in b) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
