/// Durable write-ahead log.
///
/// Every mutation is recorded here before it is applied to the storage
/// engine. [WriteAheadLog.append] returns only after the record is durable
/// according to the configured [SyncMode].
///
/// On-disk format: one or more `wal-<firstSequence>.wal` files. Each file
/// starts with the shared header (`magic u32`, `version u16`) followed by
/// framed records (`crc32 u32`, `length varint`, payload) produced by
/// `RecordCodec`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors/exceptions.dart';
import '../util/record_codec.dart';
import '../util/varint.dart';

/// Kind of a [WalEntry].
enum WalEntryType {
  /// A key/value insertion or update.
  put,

  /// A key deletion (tombstone).
  delete,

  /// Marks the start of a transaction.
  txBegin,

  /// Marks a transaction as committed; its writes become visible on replay.
  txCommit,

  /// Marks a transaction as aborted; its writes are discarded on replay.
  txAbort,

  /// Records that everything up to a sequence number is durable in storage.
  checkpoint,
}

/// A single write-ahead log record.
final class WalEntry {
  /// Creates a WAL entry.
  ///
  /// [sequenceNumber] is assigned by the log on append; the value passed here
  /// is ignored by [WriteAheadLog.append] and only meaningful on entries
  /// produced by [WriteAheadLog.replay].
  const WalEntry({
    required this.type,
    this.sequenceNumber = 0,
    this.key,
    this.value,
    this.transactionId,
    this.timestampMs = 0,
  });

  /// Convenience constructor for a put record.
  WalEntry.put(Uint8List key, Uint8List value, {int? transactionId})
    : this(
        type: WalEntryType.put,
        key: key,
        value: value,
        transactionId: transactionId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Convenience constructor for a delete (tombstone) record.
  WalEntry.delete(Uint8List key, {int? transactionId})
    : this(
        type: WalEntryType.delete,
        key: key,
        transactionId: transactionId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Convenience constructor for a transaction-begin record.
  WalEntry.txBegin(int transactionId)
    : this(
        type: WalEntryType.txBegin,
        transactionId: transactionId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Convenience constructor for a transaction-commit record.
  WalEntry.txCommit(int transactionId)
    : this(
        type: WalEntryType.txCommit,
        transactionId: transactionId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Convenience constructor for a transaction-abort record.
  WalEntry.txAbort(int transactionId)
    : this(
        type: WalEntryType.txAbort,
        transactionId: transactionId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  /// Monotonic sequence number assigned by the log.
  final int sequenceNumber;

  /// Record kind.
  final WalEntryType type;

  /// Key bytes for [WalEntryType.put] and [WalEntryType.delete] records.
  final Uint8List? key;

  /// Value bytes for [WalEntryType.put] records. May be empty (zero-length
  /// values are legitimate data, not tombstones).
  final Uint8List? value;

  /// Owning transaction, or null for autonomous writes.
  final int? transactionId;

  /// Wall-clock creation time in milliseconds since epoch.
  final int timestampMs;

  /// Returns a copy with [sequenceNumber] replaced.
  WalEntry _withSequence(int seq) => WalEntry(
    type: type,
    sequenceNumber: seq,
    key: key,
    value: value,
    transactionId: transactionId,
    timestampMs: timestampMs,
  );

  static const int _flagHasKey = 1;
  static const int _flagHasValue = 2;
  static const int _flagHasTx = 4;

  /// Encodes this entry as a record payload (framing is added by the log).
  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    out.addByte(type.index);
    final fixed =
        ByteData(16)
          ..setUint64(0, sequenceNumber, Endian.little)
          ..setUint64(8, timestampMs, Endian.little);
    out.add(fixed.buffer.asUint8List());
    var flags = 0;
    if (key != null) flags |= _flagHasKey;
    if (value != null) flags |= _flagHasValue;
    if (transactionId != null) flags |= _flagHasTx;
    out.addByte(flags);
    if (transactionId != null) {
      final tx = ByteData(8)..setUint64(0, transactionId!, Endian.little);
      out.add(tx.buffer.asUint8List());
    }
    if (key != null) {
      Varint.write(out, key!.length);
      out.add(key!);
    }
    if (value != null) {
      Varint.write(out, value!.length);
      out.add(value!);
    }
    return out.takeBytes();
  }

  /// Decodes an entry from a record [payload].
  ///
  /// Throws [CorruptionException] if the payload is malformed.
  static WalEntry decode(Uint8List payload, {String? path, int? offset}) {
    try {
      var pos = 0;
      final typeIndex = payload[pos++];
      if (typeIndex >= WalEntryType.values.length) {
        throw CorruptionException(
          'Unknown WAL entry type $typeIndex',
          path: path,
          offset: offset,
        );
      }
      final type = WalEntryType.values[typeIndex];
      final fixed = ByteData.sublistView(payload, pos, pos + 16);
      final seq = fixed.getUint64(0, Endian.little);
      final ts = fixed.getUint64(8, Endian.little);
      pos += 16;
      final flags = payload[pos++];
      int? txId;
      if (flags & _flagHasTx != 0) {
        txId = ByteData.sublistView(
          payload,
          pos,
          pos + 8,
        ).getUint64(0, Endian.little);
        pos += 8;
      }
      Uint8List? key;
      if (flags & _flagHasKey != 0) {
        final (len, n) = Varint.read(payload, pos);
        pos += n;
        key = Uint8List.sublistView(payload, pos, pos + len);
        pos += len;
      }
      Uint8List? value;
      if (flags & _flagHasValue != 0) {
        final (len, n) = Varint.read(payload, pos);
        pos += n;
        value = Uint8List.sublistView(payload, pos, pos + len);
        pos += len;
      }
      if (pos != payload.length) {
        throw CorruptionException(
          'WAL entry payload has ${payload.length - pos} trailing bytes',
          path: path,
          offset: offset,
        );
      }
      return WalEntry(
        type: type,
        sequenceNumber: seq,
        key: key,
        value: value,
        transactionId: txId,
        timestampMs: ts,
      );
    } on CorruptionException {
      rethrow;
    } catch (e) {
      throw CorruptionException(
        'Malformed WAL entry payload',
        path: path,
        offset: offset,
        cause: e,
      );
    }
  }
}

/// How durable an acknowledged append is.
enum SyncMode {
  /// Records are buffered in memory and written opportunistically. Fastest;
  /// a crash may lose recently acknowledged writes.
  none,

  /// Records are handed to the operating system (`write`) before the append
  /// returns. Survives process death, not power loss.
  os,

  /// Records are fsynced (`RandomAccessFile.flush`) before the append
  /// returns. Survives power loss.
  full,
}

/// Durable, checksummed write-ahead log.
final class WriteAheadLog {
  WriteAheadLog._(this._directory, this.syncMode, this._maxFileBytes);

  /// File-format magic: "RWL1" little-endian.
  static const int magic = 0x314C5752;

  /// File-format version.
  static const int formatVersion = 1;

  static const String _extension = '.wal';
  static const int _bufferFlushBytes = 64 * 1024;

  final String _directory;

  /// Durability level applied to every append.
  final SyncMode syncMode;

  final int _maxFileBytes;

  RandomAccessFile? _file;
  String _filePath = '';
  int _fileBytes = 0;
  int _lastSequence = 0;
  bool _closed = false;

  /// Bytes accepted under [SyncMode.none] not yet handed to the OS.
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Serializes appends, checkpoints, and close.
  Future<void> _lock = Future<void>.value();

  /// Opens (or creates) the log stored in [directory].
  ///
  /// Truncates a torn tail left by a crash in the most recent file. Throws
  /// [CorruptionException] if a non-tail region of the log fails its
  /// checksum.
  static Future<WriteAheadLog> open({
    required String directory,
    SyncMode syncMode = SyncMode.full,
    int maxFileBytes = 64 * 1024 * 1024,
  }) async {
    await Directory(directory).create(recursive: true);
    final wal = WriteAheadLog._(directory, syncMode, maxFileBytes);
    await wal._recoverTailAndOpen();
    return wal;
  }

  /// Highest sequence number assigned so far (0 if none).
  int get lastSequenceNumber => _lastSequence;

  /// Sorted list of log files, oldest first.
  Future<List<File>> _listFiles() async {
    final files = <File>[];
    await for (final e in Directory(_directory).list()) {
      if (e is File && e.path.endsWith(_extension)) files.add(e);
    }
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  static String _fileName(int firstSequence) =>
      'wal-${firstSequence.toString().padLeft(20, '0')}$_extension';

  Future<void> _recoverTailAndOpen() async {
    final files = await _listFiles();
    if (files.isNotEmpty) {
      // Only the last file needs validation before appending: it holds the
      // highest sequence numbers and may carry a torn tail from a crash.
      // Earlier files are validated by replay().
      final entries = await _readFile(files.last, truncateTornTail: true);
      for (final e in entries) {
        if (e.sequenceNumber > _lastSequence) {
          _lastSequence = e.sequenceNumber;
        }
      }
      if (entries.isEmpty) {
        final first = _firstSequenceOf(files.last.path);
        if (first != null && first - 1 > _lastSequence) {
          _lastSequence = first - 1;
        }
      }
      _filePath = files.last.path;
      _file = await File(_filePath).open(mode: FileMode.append);
      _fileBytes = await _file!.length();
    } else {
      await _openNewFile();
    }
  }

  Future<void> _openNewFile() async {
    if (_file != null) {
      await _file!.flush();
      await _file!.close();
    }
    _filePath = p.join(_directory, _fileName(_lastSequence + 1));
    final raf = await File(_filePath).open(mode: FileMode.write);
    final header = BytesBuilder(copy: false);
    RecordCodec.writeFileHeader(header, magic, formatVersion);
    final headerBytes = header.takeBytes();
    await raf.writeFrom(headerBytes);
    if (syncMode == SyncMode.full) await raf.flush();
    _file = raf;
    _fileBytes = headerBytes.length;
  }

  /// Reads and validates one WAL file.
  ///
  /// If [truncateTornTail] is true, an incomplete final record is removed
  /// from the file and reading stops there. A checksum failure that is not a
  /// pure tail (valid bytes follow, or the file is not the last one) throws
  /// [CorruptionException].
  Future<List<WalEntry>> _readFile(
    File file, {
    required bool truncateTornTail,
  }) async {
    final bytes = await file.readAsBytes();
    final entries = <WalEntry>[];
    final start = RecordCodec.readFileHeader(
      bytes,
      magic,
      formatVersion,
      path: file.path,
    );
    final reader = RecordReader(bytes, start);
    while (true) {
      final r = reader.next();
      switch (r.status) {
        case RecordReadStatus.ok:
          entries.add(
            WalEntry.decode(
              r.payload!,
              path: file.path,
              offset: r.recordOffset,
            ),
          );
        case RecordReadStatus.endOfBuffer:
          return entries;
        case RecordReadStatus.tornTail:
          if (!truncateTornTail) {
            throw CorruptionException(
              'Torn record in non-final WAL file',
              path: file.path,
              offset: r.recordOffset,
            );
          }
          await _truncateFile(file, r.recordOffset);
          return entries;
        case RecordReadStatus.crcMismatch:
          // A corrupt final record that reaches end-of-file is treated as a
          // torn write and truncated; corruption followed by surviving data
          // is unrecoverable.
          if (truncateTornTail && _frameEndsAtEof(bytes, r.recordOffset)) {
            await _truncateFile(file, r.recordOffset);
            return entries;
          }
          throw CorruptionException(
            'WAL record checksum mismatch',
            path: file.path,
            offset: r.recordOffset,
          );
      }
    }
  }

  /// Whether the frame starting at [offset] extends exactly to end of buffer.
  static bool _frameEndsAtEof(Uint8List bytes, int offset) {
    try {
      final (length, n) = Varint.read(bytes, offset + 4);
      return offset + 4 + n + length >= bytes.length;
    } on CorruptionException {
      return true;
    }
  }

  static Future<void> _truncateFile(File file, int length) async {
    final raf = await file.open(mode: FileMode.append);
    await raf.truncate(length);
    await raf.flush();
    await raf.close();
  }

  /// Runs [action] holding the append lock.
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const DatabaseClosedException('Write-ahead log is closed');
    }
  }

  /// Appends [entry] and returns its assigned sequence number.
  ///
  /// Returns only after the entry is durable per [syncMode].
  Future<int> append(WalEntry entry) async {
    await appendAll([entry]);
    return _lastSequence;
  }

  /// Appends [entries] with a single durability barrier for the whole batch.
  ///
  /// Sequence numbers are assigned in list order.
  Future<void> appendAll(List<WalEntry> entries) {
    if (entries.isEmpty) return Future<void>.value();
    return _synchronized(() async {
      _ensureOpen();
      final buf = BytesBuilder(copy: false);
      for (final e in entries) {
        final stamped = e._withSequence(++_lastSequence);
        RecordCodec.writeRecord(buf, stamped.encode());
      }
      await _write(buf.takeBytes());
    });
  }

  /// Escalates the durability of everything appended so far to [mode].
  ///
  /// Used by the database facade to honor a per-write sync override that is
  /// stronger than the log's configured [syncMode]: the batch is appended
  /// normally and then this method pushes it to the OS ([SyncMode.os]) or
  /// fsyncs it ([SyncMode.full]) before the write is acknowledged. Passing a
  /// mode weaker than or equal to what already happened is a no-op.
  Future<void> syncTo(SyncMode mode) {
    if (mode == SyncMode.none) return Future<void>.value();
    return _synchronized(() async {
      _ensureOpen();
      await _flushPending();
      _fileBytes = await _file!.position();
      if (mode == SyncMode.full) {
        await _file!.flush();
      }
    });
  }

  Future<void> _write(Uint8List bytes) async {
    switch (syncMode) {
      case SyncMode.none:
        _pending.add(bytes);
        _fileBytes += bytes.length;
        if (_pending.length >= _bufferFlushBytes) {
          await _file!.writeFrom(_pending.takeBytes());
        }
      case SyncMode.os:
        await _drainPendingInto(bytes);
      case SyncMode.full:
        await _drainPendingInto(bytes);
        await _file!.flush();
    }
    if (_fileBytes >= _maxFileBytes) {
      await _flushPending();
      await _openNewFile();
    }
  }

  Future<void> _drainPendingInto(Uint8List bytes) async {
    if (_pending.isNotEmpty) {
      _pending.add(bytes);
      await _file!.writeFrom(_pending.takeBytes());
    } else {
      await _file!.writeFrom(bytes);
    }
    _fileBytes = await _file!.position();
  }

  Future<void> _flushPending() async {
    if (_pending.isNotEmpty) {
      await _file!.writeFrom(_pending.takeBytes());
    }
  }

  /// Replays committed entries recorded after the last checkpoint.
  ///
  /// Yields only [WalEntryType.put] and [WalEntryType.delete] entries, in
  /// sequence order. Writes belonging to a transaction without a matching
  /// [WalEntryType.txCommit] are discarded, as are writes covered by the
  /// newest [WalEntryType.checkpoint]. Reading stops at (and truncates) a
  /// torn final record; a mid-file checksum failure with surviving data
  /// throws [CorruptionException]. Idempotent: replaying twice yields the
  /// same entries.
  Stream<WalEntry> replay() async* {
    _ensureOpen();
    final files = await _listFiles();
    final all = <WalEntry>[];
    for (var i = 0; i < files.length; i++) {
      all.addAll(
        await _readFile(files[i], truncateTornTail: i == files.length - 1),
      );
    }
    var checkpointFloor = 0;
    final committed = <int>{};
    final aborted = <int>{};
    for (final e in all) {
      switch (e.type) {
        case WalEntryType.checkpoint:
          final upTo = _checkpointTarget(e);
          if (upTo > checkpointFloor) checkpointFloor = upTo;
        case WalEntryType.txCommit:
          committed.add(e.transactionId!);
        case WalEntryType.txAbort:
          aborted.add(e.transactionId!);
        case WalEntryType.put:
        case WalEntryType.delete:
        case WalEntryType.txBegin:
          break;
      }
    }
    for (final e in all) {
      if (e.sequenceNumber <= checkpointFloor) continue;
      if (e.type != WalEntryType.put && e.type != WalEntryType.delete) {
        continue;
      }
      final tx = e.transactionId;
      if (tx != null && (!committed.contains(tx) || aborted.contains(tx))) {
        continue;
      }
      yield e;
    }
  }

  static int _checkpointTarget(WalEntry e) {
    final v = e.value;
    if (v == null || v.length != 8) {
      throw CorruptionException('Malformed checkpoint record');
    }
    return ByteData.sublistView(v).getUint64(0, Endian.little);
  }

  /// Records that all entries with sequence numbers up to and including
  /// [upToSequence] are durably persisted by the storage layer, then deletes
  /// log files made fully obsolete by that fact.
  Future<void> checkpoint(int upToSequence) {
    return _synchronized(() async {
      _ensureOpen();
      // Rotate first so the checkpoint record lands in a fresh file and the
      // previous file becomes eligible for deletion.
      await _flushPending();
      await _openNewFile();
      final target = ByteData(8)..setUint64(0, upToSequence, Endian.little);
      final entry = WalEntry(
        type: WalEntryType.checkpoint,
        value: target.buffer.asUint8List(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      )._withSequence(++_lastSequence);
      final buf = BytesBuilder(copy: false);
      RecordCodec.writeRecord(buf, entry.encode());
      await _file!.writeFrom(buf.takeBytes());
      // A checkpoint authorizes file deletion; it must itself be durable.
      await _file!.flush();
      _fileBytes = await _file!.position();

      final files = await _listFiles();
      for (var i = 0; i + 1 < files.length; i++) {
        final nextFirst = _firstSequenceOf(files[i + 1].path);
        // File i only contains sequences < nextFirst.
        if (nextFirst != null && nextFirst - 1 <= upToSequence) {
          await files[i].delete();
        }
      }
    });
  }

  static int? _firstSequenceOf(String filePath) {
    final name = p.basename(filePath);
    if (!name.startsWith('wal-') || !name.endsWith(_extension)) return null;
    return int.tryParse(name.substring(4, name.length - _extension.length));
  }

  /// Flushes and closes the log. Safe to call more than once.
  Future<void> close() {
    return _synchronized(() async {
      if (_closed) return;
      _closed = true;
      await _flushPending();
      await _file!.flush();
      await _file!.close();
      _file = null;
    });
  }
}
