/// Framed, checksummed binary record codec shared by the WAL and SSTables.
///
/// File layout: `[magic u32 LE][format version u16 LE]` header, followed by
/// records. Each record is `[crc32 u32 LE over payload][payload length
/// varint][payload bytes]`.
library;

import 'dart:typed_data';

import '../errors/exceptions.dart';
import 'varint.dart';

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320).
abstract final class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }

  /// Computes the CRC-32 checksum of [bytes].
  static int compute(Uint8List bytes) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      crc = _table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// Why [RecordReader.next] stopped producing records.
enum RecordReadStatus {
  /// A complete, checksum-valid record was returned.
  ok,

  /// Clean end of the buffer: no bytes remain after the last record.
  endOfBuffer,

  /// The remaining bytes are too short to hold a complete record (torn tail).
  tornTail,

  /// A complete record was present but its CRC did not match.
  crcMismatch,
}

/// Result of reading one record from a buffer.
final class RecordReadResult {
  /// Creates a read result.
  const RecordReadResult(this.status, this.payload, this.recordOffset);

  /// Outcome of the read attempt.
  final RecordReadStatus status;

  /// Record payload when [status] is [RecordReadStatus.ok], otherwise null.
  final Uint8List? payload;

  /// Byte offset at which this record (or failure) starts.
  final int recordOffset;
}

/// Encodes and decodes the shared file header and record frames.
abstract final class RecordCodec {
  /// Size in bytes of the file header (`magic u32` + `version u16`).
  static const int fileHeaderSize = 6;

  /// Writes the file header for [magic] and [version] into [out].
  static void writeFileHeader(BytesBuilder out, int magic, int version) {
    final b = ByteData(fileHeaderSize);
    b.setUint32(0, magic, Endian.little);
    b.setUint16(4, version, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  /// Validates the file header of [bytes] against [magic] and [version].
  ///
  /// Returns the offset of the first record. Throws [CorruptionException] if
  /// the header is missing, has the wrong magic, or an unsupported version.
  static int readFileHeader(
    Uint8List bytes,
    int magic,
    int version, {
    String? path,
  }) {
    if (bytes.length < fileHeaderSize) {
      throw CorruptionException(
        'File too short for header (${bytes.length} bytes)',
        path: path,
        offset: 0,
      );
    }
    final b = ByteData.sublistView(bytes, 0, fileHeaderSize);
    final gotMagic = b.getUint32(0, Endian.little);
    if (gotMagic != magic) {
      throw CorruptionException(
        'Bad magic 0x${gotMagic.toRadixString(16)}, '
        'expected 0x${magic.toRadixString(16)}',
        path: path,
        offset: 0,
      );
    }
    final gotVersion = b.getUint16(4, Endian.little);
    if (gotVersion != version) {
      throw CorruptionException(
        'Unsupported format version $gotVersion, expected $version',
        path: path,
        offset: 4,
      );
    }
    return fileHeaderSize;
  }

  /// Appends one framed record containing [payload] to [out].
  static void writeRecord(BytesBuilder out, Uint8List payload) {
    final crc = ByteData(4)
      ..setUint32(0, Crc32.compute(payload), Endian.little);
    out.add(crc.buffer.asUint8List());
    Varint.write(out, payload.length);
    out.add(payload);
  }

  /// Encodes one framed record as a standalone byte list.
  static Uint8List encodeRecord(Uint8List payload) {
    final b = BytesBuilder(copy: false);
    writeRecord(b, payload);
    return b.takeBytes();
  }
}

/// Sequential reader over a buffer of framed records.
final class RecordReader {
  /// Creates a reader over [bytes] positioned at [offset] (normally just past
  /// the file header).
  RecordReader(this.bytes, this.offset);

  /// The buffer being read.
  final Uint8List bytes;

  /// Current read position.
  int offset;

  /// Attempts to read the next record.
  ///
  /// Never throws; inspect [RecordReadResult.status]. On
  /// [RecordReadStatus.ok] the reader advances past the record; on any other
  /// status the reader does not advance.
  RecordReadResult next() {
    final start = offset;
    if (start >= bytes.length) {
      return RecordReadResult(RecordReadStatus.endOfBuffer, null, start);
    }
    if (start + 4 > bytes.length) {
      return RecordReadResult(RecordReadStatus.tornTail, null, start);
    }
    final storedCrc = ByteData.sublistView(
      bytes,
      start,
      start + 4,
    ).getUint32(0, Endian.little);
    // Decode the length varint manually to distinguish a truncated buffer
    // (torn tail) from a malformed over-long varint (corruption).
    var length = 0;
    var shift = 0;
    var lengthBytes = 0;
    var i = start + 4;
    while (true) {
      if (i >= bytes.length) {
        return RecordReadResult(RecordReadStatus.tornTail, null, start);
      }
      if (lengthBytes >= Varint.maxBytes) {
        return RecordReadResult(RecordReadStatus.crcMismatch, null, start);
      }
      final b = bytes[i];
      length |= (b & 0x7f) << shift;
      i++;
      lengthBytes++;
      if (b < 0x80) break;
      shift += 7;
    }
    final payloadStart = start + 4 + lengthBytes;
    final payloadEnd = payloadStart + length;
    if (payloadEnd > bytes.length) {
      return RecordReadResult(RecordReadStatus.tornTail, null, start);
    }
    final payload = Uint8List.sublistView(bytes, payloadStart, payloadEnd);
    if (Crc32.compute(payload) != storedCrc) {
      return RecordReadResult(RecordReadStatus.crcMismatch, null, start);
    }
    offset = payloadEnd;
    return RecordReadResult(RecordReadStatus.ok, payload, start);
  }
}
