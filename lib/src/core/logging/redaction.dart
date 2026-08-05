import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Redaction helpers for log messages.
///
/// ## No-PII logging policy
///
/// Database keys frequently contain emails, user ids, and other personal
/// data, and values are the user's data itself. ReaxDB therefore never logs
/// key contents, value contents, encryption keys, passphrases, or derived key
/// material at ANY log level. When a key must appear in a log message for
/// debugging, pass it through [Redaction.key] first: the output is a
/// non-reversible fingerprint that lets you correlate log lines about the
/// same key without revealing it.
abstract final class Redaction {
  /// Redacts a database key to a non-reversible fingerprint such as
  /// `key#3f2a9c1d(len=17)`.
  ///
  /// The fingerprint is the first 8 hex characters of the SHA-256 of the
  /// UTF-8 key bytes: deterministic (the same key always yields the same
  /// fingerprint, so log lines can be correlated) but not reversible.
  static String key(String key) {
    final Digest digest = sha256.convert(utf8.encode(key));
    final String fingerprint =
        digest.bytes
            .take(4)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    return 'key#$fingerprint(len=${key.length})';
  }

  /// Redacts raw key bytes to a fingerprint, like [key] but for binary keys.
  static String keyBytes(Uint8List bytes) {
    final Digest digest = sha256.convert(bytes);
    final String fingerprint =
        digest.bytes
            .take(4)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    return 'key#$fingerprint(len=${bytes.length})';
  }

  /// Redacts a stored value, reporting only its runtime type and size.
  ///
  /// Never includes any part of the value's content.
  static String value(Object? value) {
    if (value == null) {
      return '<null>';
    }
    if (value is String) {
      return '<redacted String, ${value.length} chars>';
    }
    if (value is List<int>) {
      return '<redacted bytes, ${value.length} bytes>';
    }
    if (value is Map) {
      return '<redacted Map, ${value.length} entries>';
    }
    if (value is Iterable) {
      return '<redacted ${value.runtimeType}, ${value.length} items>';
    }
    return '<redacted ${value.runtimeType}>';
  }
}
