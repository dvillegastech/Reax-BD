/// Unsigned LEB128 variable-length integer encoding.
library;

import 'dart:typed_data';

import '../errors/exceptions.dart';

/// Encodes and decodes unsigned varints (LEB128, low 7 bits per byte).
abstract final class Varint {
  /// Maximum encoded size of a 64-bit varint.
  static const int maxBytes = 10;

  /// Appends the varint encoding of non-negative [value] to [out].
  static void write(BytesBuilder out, int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be non-negative');
    }
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  /// Encodes non-negative [value] as a standalone byte list.
  static Uint8List encode(int value) {
    final b = BytesBuilder(copy: false);
    write(b, value);
    return b.takeBytes();
  }

  /// Number of bytes [value] occupies when varint-encoded.
  static int sizeOf(int value) {
    var v = value;
    var n = 1;
    while (v >= 0x80) {
      v >>= 7;
      n++;
    }
    return n;
  }

  /// Reads a varint from [bytes] starting at [offset].
  ///
  /// Returns the decoded value and the number of bytes consumed. Throws
  /// [CorruptionException] if the buffer ends mid-varint or the encoding
  /// exceeds [maxBytes].
  static (int value, int bytesRead) read(Uint8List bytes, int offset) {
    var result = 0;
    var shift = 0;
    var i = offset;
    while (true) {
      if (i >= bytes.length) {
        throw CorruptionException(
          'Truncated varint at offset $offset',
          offset: offset,
        );
      }
      if (i - offset >= maxBytes) {
        throw CorruptionException(
          'Varint too long at offset $offset',
          offset: offset,
        );
      }
      final b = bytes[i];
      result |= (b & 0x7f) << shift;
      i++;
      if (b < 0x80) return (result, i - offset);
      shift += 7;
    }
  }
}
