import 'dart:typed_data';

import 'package:reaxdb_dart/src/core/errors/exceptions.dart';
import 'package:reaxdb_dart/src/core/util/record_codec.dart';
import 'package:reaxdb_dart/src/core/util/varint.dart';
import 'package:test/test.dart';

void main() {
  group('Varint', () {
    test('round-trips boundary values', () {
      for (final v in [0, 1, 127, 128, 300, 16383, 16384, 1 << 40, 1 << 62]) {
        final encoded = Varint.encode(v);
        final (decoded, n) = Varint.read(encoded, 0);
        expect(decoded, v);
        expect(n, encoded.length);
        expect(Varint.sizeOf(v), encoded.length);
      }
    });

    test('throws CorruptionException on a truncated varint', () {
      expect(
        () => Varint.read(Uint8List.fromList([0x80, 0x80]), 0),
        throwsA(isA<CorruptionException>()),
      );
    });
  });

  group('Crc32', () {
    test('matches the known IEEE vector', () {
      final bytes = Uint8List.fromList('123456789'.codeUnits);
      expect(Crc32.compute(bytes), 0xCBF43926);
    });

    test('detects single-bit changes', () {
      final bytes = Uint8List.fromList(List.generate(64, (i) => i));
      final crc = Crc32.compute(bytes);
      bytes[10] ^= 1;
      expect(Crc32.compute(bytes), isNot(crc));
    });
  });

  group('RecordCodec', () {
    test('file header round-trips and rejects bad magic/version', () {
      final out = BytesBuilder();
      RecordCodec.writeFileHeader(out, 0xABCD1234, 7);
      final bytes = out.takeBytes();
      expect(RecordCodec.readFileHeader(bytes, 0xABCD1234, 7), 6);
      expect(
        () => RecordCodec.readFileHeader(bytes, 0xABCD1235, 7),
        throwsA(isA<CorruptionException>()),
      );
      expect(
        () => RecordCodec.readFileHeader(bytes, 0xABCD1234, 8),
        throwsA(isA<CorruptionException>()),
      );
      expect(
        () => RecordCodec.readFileHeader(Uint8List(3), 0xABCD1234, 7),
        throwsA(isA<CorruptionException>()),
      );
    });

    test('records round-trip, including empty payloads', () {
      final out = BytesBuilder();
      final payloads = [
        Uint8List(0),
        Uint8List.fromList([42]),
        Uint8List.fromList(List.generate(1000, (i) => i & 0xff)),
      ];
      for (final payload in payloads) {
        RecordCodec.writeRecord(out, payload);
      }
      final reader = RecordReader(out.takeBytes(), 0);
      for (final payload in payloads) {
        final r = reader.next();
        expect(r.status, RecordReadStatus.ok);
        expect(r.payload, payload);
      }
      expect(reader.next().status, RecordReadStatus.endOfBuffer);
    });

    test('reports a torn tail without advancing', () {
      final out = BytesBuilder();
      RecordCodec.writeRecord(out, Uint8List.fromList([1, 2, 3]));
      final full = out.takeBytes();
      final torn = Uint8List.sublistView(full, 0, full.length - 1);
      final reader = RecordReader(torn, 0);
      expect(reader.next().status, RecordReadStatus.tornTail);
      expect(reader.offset, 0);
    });

    test('reports a CRC mismatch on a corrupted payload', () {
      final out = BytesBuilder();
      RecordCodec.writeRecord(out, Uint8List.fromList([1, 2, 3, 4]));
      final bytes = out.takeBytes();
      bytes[bytes.length - 1] ^= 0xff;
      expect(
        RecordReader(bytes, 0).next().status,
        RecordReadStatus.crcMismatch,
      );
    });
  });
}
