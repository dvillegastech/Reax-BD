/// Read-only decoder for the ReaxDB 1.x value envelope.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/errors/exceptions.dart';

/// Decodes the value envelope ReaxDB 1.x wrote for every stored record.
///
/// ## Format (from `ReaxDB.serializeValue` in 1.4.1)
///
/// ```text
/// String     [0x00][length u32 LE][utf8 bytes]
/// int        [0x01][int64 LE]                      (9 bytes total)
/// double     [0x02][float64 LE]                    (9 bytes total)
/// bool       [0x03][0x00 | 0x01]                   (2 bytes total)
/// List<int>  [0x04][length u32 LE][raw bytes]
/// other      [0xFF][length u32 LE][utf8 of jsonEncode(value)]
/// ```
///
/// The 1.x decoder was lenient: on any failure it retried `jsonDecode` over
/// the whole buffer and finally returned `null`, which silently turned a
/// damaged record into a missing one. This decoder is strict on purpose: it
/// throws, so the migrator can count the record as skipped and report it, and
/// so a wrong legacy encryption key is detectable (garbage plaintext does not
/// satisfy the length invariants).
abstract final class LegacyValueCodec {
  /// Type marker for a `String` value.
  static const int tagString = 0x00;

  /// Type marker for an `int` value.
  static const int tagInt = 0x01;

  /// Type marker for a `double` value.
  static const int tagDouble = 0x02;

  /// Type marker for a `bool` value.
  static const int tagBool = 0x03;

  /// Type marker for a `List<int>` value.
  static const int tagBytes = 0x04;

  /// Type marker for any other JSON-encodable value.
  static const int tagJson = 0xFF;

  /// Decodes a 1.x envelope into the Dart value 1.x would have returned.
  ///
  /// Returns a `String`, `int`, `double`, `bool`, [Uint8List] or the result of
  /// `jsonDecode`. Throws [SerializationException] when [bytes] is not a
  /// well-formed 1.x envelope.
  static Object? decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const SerializationException(
        'Empty ReaxDB 1.x value envelope (a zero-length record is a 1.x '
        'tombstone and must be handled before decoding)',
      );
    }
    final int tag = bytes[0];
    try {
      return _decodeTagged(bytes, tag);
    } on FormatException catch (error) {
      throw SerializationException(
        'ReaxDB 1.x envelope with marker 0x${tag.toRadixString(16)} does not '
        'hold decodable text',
        cause: error,
      );
    }
  }

  static Object? _decodeTagged(Uint8List bytes, int tag) {
    switch (tag) {
      case tagString:
        return utf8.decode(_payload(bytes, tag));
      case tagInt:
        _expectLength(bytes, 9, tag);
        return ByteData.sublistView(bytes, 1, 9).getInt64(0, Endian.little);
      case tagDouble:
        _expectLength(bytes, 9, tag);
        return ByteData.sublistView(bytes, 1, 9).getFloat64(0, Endian.little);
      case tagBool:
        _expectLength(bytes, 2, tag);
        if (bytes[1] > 1) {
          throw SerializationException(
            'ReaxDB 1.x bool envelope carries the invalid byte ${bytes[1]}',
          );
        }
        return bytes[1] == 1;
      case tagBytes:
        return Uint8List.fromList(_payload(bytes, tag));
      case tagJson:
        return jsonDecode(utf8.decode(_payload(bytes, tag)));
      default:
        throw SerializationException(
          'Unknown ReaxDB 1.x value type marker 0x${tag.toRadixString(16)}',
        );
    }
  }

  /// Whether [bytes] is a well-formed 1.x envelope.
  ///
  /// Used to probe which 1.x cipher a database was written with, and to decide
  /// whether a supplied legacy key is the right one.
  static bool isValid(Uint8List bytes) {
    try {
      decode(bytes);
      return true;
    } on SerializationException {
      return false;
    }
  }

  static Uint8List _payload(Uint8List bytes, int tag) {
    if (bytes.length < 5) {
      throw SerializationException(
        'ReaxDB 1.x envelope with marker 0x${tag.toRadixString(16)} is '
        '${bytes.length} bytes, too short for its 5 byte header',
      );
    }
    final int length = ByteData.sublistView(
      bytes,
      1,
      5,
    ).getUint32(0, Endian.little);
    if (length != bytes.length - 5) {
      throw SerializationException(
        'ReaxDB 1.x envelope with marker 0x${tag.toRadixString(16)} declares '
        '$length payload bytes but carries ${bytes.length - 5}',
      );
    }
    return Uint8List.sublistView(bytes, 5);
  }

  static void _expectLength(Uint8List bytes, int expected, int tag) {
    if (bytes.length != expected) {
      throw SerializationException(
        'ReaxDB 1.x envelope with marker 0x${tag.toRadixString(16)} must be '
        '$expected bytes but is ${bytes.length}',
      );
    }
  }
}
