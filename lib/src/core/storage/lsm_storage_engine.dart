/// LSM-only implementation of [StorageEngine].
///
/// Every mutation flows through one pipeline: the write-ahead log first
/// (durable per the configured [SyncMode] before the call returns), then the
/// memtable. Full memtables are flushed inline to an L0 SSTable and the WAL
/// is checkpointed, so an acknowledged write is always recoverable from
/// either the WAL or an SSTable.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors/exceptions.dart';
import '../util/byte_key.dart';
import '../wal/write_ahead_log.dart';
import 'lsm_tree.dart';
import 'memtable.dart';
import 'sstable.dart';
import 'storage_engine.dart';

/// Durable ordered key/value engine backed by a WAL and a leveled LSM tree.
final class LsmStorageEngine implements StorageEngine {
  LsmStorageEngine._(
    this._directory,
    this._wal,
    this._lsm,
    this._memtableSizeBytes,
  ) : _memtable = MemTable(maxSizeBytes: _memtableSizeBytes);

  /// Namespace for internally generated batch transaction ids, chosen so it
  /// cannot collide with caller-supplied ids from the transaction manager.
  static const int _internalTxBase = 0x4000000000000000;

  final String _directory;
  final WriteAheadLog _wal;
  final LsmTree _lsm;
  final int _memtableSizeBytes;

  MemTable _memtable;
  bool _closed = false;
  int _internalTxCounter = 0;

  /// Serializes every mutation, flush, compaction, and close.
  Future<void> _writeLock = Future<void>.value();

  /// Opens (or creates) an engine rooted at [directory].
  ///
  /// Layout: `directory/wal/` holds WAL segments, `directory/tables/` holds
  /// the manifest and SSTables. Committed WAL entries newer than the last
  /// checkpoint are replayed into the memtable before the engine is
  /// returned.
  static Future<LsmStorageEngine> open({
    required String directory,
    SyncMode syncMode = SyncMode.full,
    int memtableSizeBytes = 4 * 1024 * 1024,
    int walMaxFileBytes = 16 * 1024 * 1024,
    int maxLevels = 4,
    int l0CompactionTrigger = 4,
    int baseLevelTargetBytes = 8 * 1024 * 1024,
    int levelSizeMultiplier = 10,
    int targetTableBytes = 2 * 1024 * 1024,
  }) async {
    await Directory(directory).create(recursive: true);
    final lsm = await LsmTree.open(
      directory: p.join(directory, 'tables'),
      maxLevels: maxLevels,
      l0CompactionTrigger: l0CompactionTrigger,
      baseLevelTargetBytes: baseLevelTargetBytes,
      levelSizeMultiplier: levelSizeMultiplier,
      targetTableBytes: targetTableBytes,
    );
    final wal = await WriteAheadLog.open(
      directory: p.join(directory, 'wal'),
      syncMode: syncMode,
      maxFileBytes: walMaxFileBytes,
    );
    final engine = LsmStorageEngine._(directory, wal, lsm, memtableSizeBytes);
    await for (final entry in wal.replay()) {
      if (entry.type == WalEntryType.put) {
        engine._memtable.put(entry.key!, entry.value!);
      } else {
        engine._memtable.delete(entry.key!);
      }
    }
    if (engine._memtable.isFull) {
      await engine._flushLocked();
    }
    return engine;
  }

  /// Root directory of this engine.
  String get directory => _directory;

  void _ensureOpen() {
    if (_closed) {
      throw const DatabaseClosedException('Storage engine is closed');
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _writeLock.then((_) => action());
    _writeLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> put(Uint8List key, Uint8List value) =>
      writeBatch([WriteOp.put(key, value)]);

  @override
  Future<void> delete(Uint8List key) => writeBatch([WriteOp.delete(key)]);

  @override
  Future<void> writeBatch(List<WriteOp> ops, {int? transactionId}) {
    if (ops.isEmpty) return Future<void>.value();
    return _synchronized(() async {
      _ensureOpen();
      final entries = <WalEntry>[];
      int? txId = transactionId;
      final needsTxFraming = ops.length > 1 || txId != null;
      if (needsTxFraming) {
        txId ??= _internalTxBase + _internalTxCounter++;
        entries.add(WalEntry.txBegin(txId));
      }
      for (final op in ops) {
        entries.add(
          op.isDelete
              ? WalEntry.delete(op.key, transactionId: txId)
              : WalEntry.put(op.key, op.value!, transactionId: txId),
        );
      }
      if (needsTxFraming) {
        entries.add(WalEntry.txCommit(txId!));
      }
      // Durability point: appendAll returns only after the batch is durable
      // per the WAL's sync mode.
      await _wal.appendAll(entries);
      for (final op in ops) {
        if (op.isDelete) {
          _memtable.delete(op.key);
        } else {
          _memtable.put(op.key, op.value!);
        }
      }
      if (_memtable.isFull) {
        await _flushLocked();
      }
    });
  }

  @override
  Future<Uint8List?> get(Uint8List key) async {
    _ensureOpen();
    final slot = _memtable.lookup(key);
    if (slot != null) return slot.value;
    final entry = await _lsm.get(key);
    return entry?.value;
  }

  @override
  Stream<KeyValue> scan({
    Uint8List? startKey,
    Uint8List? endKey,
    int? limit,
    bool reverse = false,
  }) {
    _ensureOpen();
    // Snapshot the memtable slice so concurrent writes cannot invalidate the
    // iterator mid-scan; the LSM sources are immutable files captured now.
    final memEntries = <SSTableEntry>[
      for (final e in _memtable.range(
        startKey == null ? null : ByteKey(startKey),
        endKey == null ? null : ByteKey(endKey),
      ))
        e.value.isTombstone
            ? SSTableEntry.tombstone(e.key.bytes)
            : SSTableEntry(e.key.bytes, e.value.value!),
    ];
    final memStream = Stream.fromIterable(
      reverse ? memEntries.reversed : memEntries,
    );
    final merged = LsmTree.mergeEntryStreams([
      memStream,
      _lsm.scan(startKey: startKey, endKey: endKey, reverse: reverse),
    ], reverse: reverse);
    return _liveEntries(merged, limit);
  }

  static Stream<KeyValue> _liveEntries(
    Stream<SSTableEntry> merged,
    int? limit,
  ) async* {
    var yielded = 0;
    await for (final e in merged) {
      if (e.isTombstone) continue;
      if (limit != null && yielded >= limit) return;
      yielded++;
      yield KeyValue(e.key, e.value!);
    }
  }

  /// Escalates the durability of everything written so far to [mode].
  ///
  /// The engine's configured sync mode already applies to every batch; this
  /// exists so a caller can make one individual write stronger (for example
  /// a database opened with [SyncMode.os] that needs a single fsynced write).
  Future<void> syncTo(SyncMode mode) {
    _ensureOpen();
    return _wal.syncTo(mode);
  }

  /// Flushes the active memtable to an L0 table and checkpoints the WAL.
  /// Must be called while holding the write lock.
  Future<void> _flushLocked() async {
    if (_memtable.isEmpty) return;
    final flushUpTo = _wal.lastSequenceNumber;
    final entries = <SSTableEntry>[
      for (final e in _memtable.entries)
        e.value.isTombstone
            ? SSTableEntry.tombstone(e.key.bytes)
            : SSTableEntry(e.key.bytes, e.value.value!),
    ];
    await _lsm.addFlushedTable(entries);
    _memtable = MemTable(maxSizeBytes: _memtableSizeBytes);
    await _wal.checkpoint(flushUpTo);
    if (_lsm.needsCompaction) {
      await _lsm.compact();
    }
  }

  @override
  Future<void> flush() {
    return _synchronized(() async {
      _ensureOpen();
      await _flushLocked();
    });
  }

  @override
  Future<void> compact() {
    return _synchronized(() async {
      _ensureOpen();
      await _flushLocked();
      await _lsm.compact(force: true);
    });
  }

  @override
  Future<void> close() {
    return _synchronized(() async {
      if (_closed) return;
      await _flushLocked();
      _closed = true;
      await _wal.close();
      await _lsm.close();
    });
  }

  @override
  StorageStats get stats => StorageStats(
    memtableEntries: _memtable.entryCount,
    memtableSizeBytes: _memtable.sizeBytes,
    immutableMemtableCount: 0,
    sstableCount: _lsm.tableCount,
    sstableSizeBytes: _lsm.totalSizeBytes,
    levelTableCounts: _lsm.levelTableCounts,
    lastSequenceNumber: _wal.lastSequenceNumber,
  );
}
