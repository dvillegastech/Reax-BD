/// Immutable sorted string table (SSTable).
///
/// On-disk layout:
/// ```text
/// [magic u32][version u16]                      file header
/// framed data records                           crc32 + varint len + payload
/// framed meta record                            index, bloom, fences
/// [metaOffset u64][metaLength u64][magic u32]   fixed 20-byte footer
/// ```
/// A data-record payload is `[flag u8][keyLen varint][key][value...]` where
/// flag bit 0 marks a tombstone (tombstones carry no value bytes; an empty
/// value is legitimate data). Files are created under a temporary name and
/// atomically renamed into place, so a partially written table is never
/// visible under its final name.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../errors/exceptions.dart';
import '../util/byte_key.dart';
import '../util/record_codec.dart';
import '../util/varint.dart';
import 'bloom_filter.dart';

/// One entry stored in (or destined for) an SSTable.
final class SSTableEntry {
  /// Creates a live entry.
  const SSTableEntry(this.key, Uint8List this.value);

  /// Creates a tombstone entry for [key].
  const SSTableEntry.tombstone(this.key) : value = null;

  /// The key bytes.
  final Uint8List key;

  /// The value bytes, or null when this entry is a tombstone.
  final Uint8List? value;

  /// Whether this entry marks a deletion.
  bool get isTombstone => value == null;
}

final class _IndexEntry {
  const _IndexEntry(this.key, this.offset, this.length);

  final Uint8List key;
  final int offset;
  final int length;
}

/// Bounded pool of read handles so concurrent reads never share a cursor.
final class _HandlePool {
  _HandlePool(this.path, this.capacity);

  final String path;
  final int capacity;
  final List<RandomAccessFile> _free = [];
  final Queue<Completer<RandomAccessFile>> _waiters = Queue();
  int _opened = 0;
  bool _closed = false;

  Future<RandomAccessFile> acquire() async {
    if (_closed) {
      throw const DatabaseClosedException('SSTable is closed');
    }
    if (_free.isNotEmpty) return _free.removeLast();
    if (_opened < capacity) {
      _opened++;
      return File(path).open();
    }
    final c = Completer<RandomAccessFile>();
    _waiters.add(c);
    return c.future;
  }

  void release(RandomAccessFile raf) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(raf);
    } else if (_closed) {
      raf.close();
      _opened--;
    } else {
      _free.add(raf);
    }
  }

  Future<void> close() async {
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(
        const DatabaseClosedException('SSTable is closed'),
      );
    }
    for (final raf in _free) {
      await raf.close();
      _opened--;
    }
    _free.clear();
  }
}

/// An immutable, checksummed, sorted table of key/value entries.
final class SSTable {
  SSTable._(
    this.path,
    this._index,
    this._bloom,
    this.minKey,
    this.maxKey,
    this.fileSizeBytes,
    this._pool,
  );

  /// File-format magic: "RXS1" little-endian.
  static const int magic = 0x31535852;

  /// File-format version.
  static const int formatVersion = 1;

  static const int _footerSize = 20;
  static const int _flagTombstone = 1;
  static const int _readHandles = 4;

  /// Absolute path of the `.sst` file.
  final String path;

  /// Smallest key in the table.
  final Uint8List minKey;

  /// Largest key in the table.
  final Uint8List maxKey;

  /// Total file size in bytes.
  final int fileSizeBytes;

  final List<_IndexEntry> _index;
  final BloomFilter _bloom;
  final _HandlePool _pool;

  /// Number of entries, tombstones included.
  int get entryCount => _index.length;

  /// Writes [entries] (sorted ascending by key, unique) to [filePath],
  /// creating the file atomically via a temporary name plus rename, then
  /// opens it.
  static Future<SSTable> create({
    required String filePath,
    required List<SSTableEntry> entries,
    double bloomFalsePositiveRate = 0.01,
  }) async {
    if (entries.isEmpty) {
      throw ArgumentError('Cannot create an empty SSTable');
    }
    final tmpPath = '$filePath.tmp';
    final buf = BytesBuilder(copy: false);
    RecordCodec.writeFileHeader(buf, magic, formatVersion);

    final bloom = BloomFilter(
      expectedEntries: entries.length,
      falsePositiveRate: bloomFalsePositiveRate,
    );
    final index = <_IndexEntry>[];
    for (final e in entries) {
      final payload = BytesBuilder(copy: false);
      payload.addByte(e.isTombstone ? _flagTombstone : 0);
      Varint.write(payload, e.key.length);
      payload.add(e.key);
      if (!e.isTombstone) payload.add(e.value!);
      final offset = buf.length;
      RecordCodec.writeRecord(buf, payload.takeBytes());
      index.add(_IndexEntry(e.key, offset, buf.length - offset));
      bloom.add(e.key);
    }

    final metaOffset = buf.length;
    final meta = BytesBuilder(copy: false);
    Varint.write(meta, entries.length);
    final minKey = entries.first.key;
    final maxKey = entries.last.key;
    Varint.write(meta, minKey.length);
    meta.add(minKey);
    Varint.write(meta, maxKey.length);
    meta.add(maxKey);
    final bloomBytes = bloom.toBytes();
    Varint.write(meta, bloomBytes.length);
    meta.add(bloomBytes);
    for (final ix in index) {
      Varint.write(meta, ix.key.length);
      meta.add(ix.key);
      Varint.write(meta, ix.offset);
      Varint.write(meta, ix.length);
    }
    RecordCodec.writeRecord(buf, meta.takeBytes());
    final metaLength = buf.length - metaOffset;

    final footer =
        ByteData(_footerSize)
          ..setUint64(0, metaOffset, Endian.little)
          ..setUint64(8, metaLength, Endian.little)
          ..setUint32(16, magic, Endian.little);
    buf.add(footer.buffer.asUint8List());

    final raf = await File(tmpPath).open(mode: FileMode.write);
    await raf.writeFrom(buf.takeBytes());
    await raf.flush();
    await raf.close();
    await File(tmpPath).rename(filePath);
    return open(filePath);
  }

  /// Opens and validates an existing table.
  ///
  /// Throws [CorruptionException] when the file is truncated, has a bad
  /// magic, or the meta block fails its checksum.
  static Future<SSTable> open(String filePath) async {
    final file = File(filePath);
    final size = await file.length();
    if (size < RecordCodec.fileHeaderSize + _footerSize) {
      throw CorruptionException(
        'SSTable too small ($size bytes)',
        path: filePath,
      );
    }
    final raf = await file.open();
    try {
      final header = Uint8List(RecordCodec.fileHeaderSize);
      await raf.readInto(header);
      RecordCodec.readFileHeader(header, magic, formatVersion, path: filePath);

      await raf.setPosition(size - _footerSize);
      final footerBytes = Uint8List(_footerSize);
      await raf.readInto(footerBytes);
      final footer = ByteData.sublistView(footerBytes);
      if (footer.getUint32(16, Endian.little) != magic) {
        throw CorruptionException(
          'SSTable footer magic mismatch',
          path: filePath,
          offset: size - 4,
        );
      }
      final metaOffset = footer.getUint64(0, Endian.little);
      final metaLength = footer.getUint64(8, Endian.little);
      if (metaOffset < RecordCodec.fileHeaderSize ||
          metaOffset + metaLength != size - _footerSize) {
        throw CorruptionException(
          'SSTable footer describes an invalid meta block',
          path: filePath,
          offset: size - _footerSize,
        );
      }
      await raf.setPosition(metaOffset);
      final metaFrame = Uint8List(metaLength);
      await raf.readInto(metaFrame);
      final reader = RecordReader(metaFrame, 0);
      final r = reader.next();
      if (r.status != RecordReadStatus.ok || reader.offset != metaLength) {
        throw CorruptionException(
          'SSTable meta block failed validation',
          path: filePath,
          offset: metaOffset,
        );
      }
      final meta = r.payload!;
      var pos = 0;
      final (count, n0) = Varint.read(meta, pos);
      pos += n0;
      final (minLen, n1) = Varint.read(meta, pos);
      pos += n1;
      final minKey = Uint8List.fromList(
        Uint8List.sublistView(meta, pos, pos + minLen),
      );
      pos += minLen;
      final (maxLen, n2) = Varint.read(meta, pos);
      pos += n2;
      final maxKey = Uint8List.fromList(
        Uint8List.sublistView(meta, pos, pos + maxLen),
      );
      pos += maxLen;
      final (bloomLen, n3) = Varint.read(meta, pos);
      pos += n3;
      final bloom = BloomFilter.fromBytes(
        Uint8List.sublistView(meta, pos, pos + bloomLen),
      );
      pos += bloomLen;
      final index = <_IndexEntry>[];
      for (var i = 0; i < count; i++) {
        final (keyLen, a) = Varint.read(meta, pos);
        pos += a;
        final key = Uint8List.fromList(
          Uint8List.sublistView(meta, pos, pos + keyLen),
        );
        pos += keyLen;
        final (offset, b) = Varint.read(meta, pos);
        pos += b;
        final (length, c) = Varint.read(meta, pos);
        pos += c;
        index.add(_IndexEntry(key, offset, length));
      }
      if (pos != meta.length) {
        throw CorruptionException(
          'SSTable meta block has trailing bytes',
          path: filePath,
          offset: metaOffset,
        );
      }
      return SSTable._(
        filePath,
        index,
        bloom,
        minKey,
        maxKey,
        size,
        _HandlePool(filePath, _readHandles),
      );
    } on CorruptionException {
      rethrow;
    } on RangeError catch (e) {
      throw CorruptionException(
        'SSTable meta block is malformed',
        path: filePath,
        cause: e,
      );
    } finally {
      await raf.close();
    }
  }

  /// Binary search: index of the first entry with key >= [key].
  int _lowerBound(Uint8List key) {
    var lo = 0;
    var hi = _index.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ByteKey.compareBytes(_index[mid].key, key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Looks up [key].
  ///
  /// Returns null when the key is not in this table; otherwise the entry
  /// (which may be a tombstone).
  Future<SSTableEntry?> get(Uint8List key) async {
    if (ByteKey.compareBytes(key, minKey) < 0 ||
        ByteKey.compareBytes(key, maxKey) > 0) {
      return null;
    }
    if (!_bloom.mightContain(key)) return null;
    final i = _lowerBound(key);
    if (i >= _index.length || ByteKey.compareBytes(_index[i].key, key) != 0) {
      return null;
    }
    final entries = await _readSpan(_index[i].offset, _index[i].length);
    return entries.single;
  }

  /// Reads and decodes the frames in `[offset, offset + length)` using a
  /// pooled handle so concurrent reads never interleave a shared cursor.
  Future<List<SSTableEntry>> _readSpan(int offset, int length) async {
    final raf = await _pool.acquire();
    final bytes = Uint8List(length);
    try {
      await raf.setPosition(offset);
      final got = await raf.readInto(bytes);
      if (got != length) {
        throw CorruptionException(
          'Short read from SSTable',
          path: path,
          offset: offset,
        );
      }
    } finally {
      _pool.release(raf);
    }
    return _decodeFrames(bytes, offset);
  }

  List<SSTableEntry> _decodeFrames(Uint8List bytes, int baseOffset) {
    final out = <SSTableEntry>[];
    final reader = RecordReader(bytes, 0);
    while (true) {
      final r = reader.next();
      if (r.status == RecordReadStatus.endOfBuffer) return out;
      if (r.status != RecordReadStatus.ok) {
        throw CorruptionException(
          'SSTable data record failed validation',
          path: path,
          offset: baseOffset + r.recordOffset,
        );
      }
      final payload = r.payload!;
      final flag = payload[0];
      final (keyLen, n) = Varint.read(payload, 1);
      final keyStart = 1 + n;
      final key = Uint8List.fromList(
        Uint8List.sublistView(payload, keyStart, keyStart + keyLen),
      );
      if (flag & _flagTombstone != 0) {
        out.add(SSTableEntry.tombstone(key));
      } else {
        out.add(
          SSTableEntry(
            key,
            Uint8List.fromList(
              Uint8List.sublistView(payload, keyStart + keyLen),
            ),
          ),
        );
      }
    }
  }

  /// Streams entries with `startKey <= key < endKey` in key order
  /// ([reverse] flips direction). Null bounds are unbounded. The byte span
  /// covering the range is read with one positional read.
  Stream<SSTableEntry> range({
    Uint8List? startKey,
    Uint8List? endKey,
    bool reverse = false,
  }) async* {
    if (_index.isEmpty) return;
    final lo = startKey == null ? 0 : _lowerBound(startKey);
    final hi = endKey == null ? _index.length : _lowerBound(endKey);
    if (lo >= hi) return;
    final begin = _index[lo].offset;
    final end = _index[hi - 1].offset + _index[hi - 1].length;
    final entries = await _readSpan(begin, end - begin);
    if (reverse) {
      for (var i = entries.length - 1; i >= 0; i--) {
        yield entries[i];
      }
    } else {
      yield* Stream.fromIterable(entries);
    }
  }

  /// Streams every entry in key order (used by compaction).
  Stream<SSTableEntry> scanAll() => range();

  /// Releases read handles. The file itself is immutable and remains valid.
  Future<void> close() => _pool.close();
}
