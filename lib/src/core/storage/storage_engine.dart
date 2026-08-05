/// Storage engine contract shared by all higher layers.
library;

import 'dart:typed_data';

/// A single mutation applied through [StorageEngine.writeBatch].
final class WriteOp {
  /// Creates a put operation for [key] = [value].
  WriteOp.put(this.key, Uint8List this.value);

  /// Creates a delete (tombstone) operation for [key].
  WriteOp.delete(this.key) : value = null;

  /// The key being written.
  final Uint8List key;

  /// The value for a put, or null for a delete.
  final Uint8List? value;

  /// Whether this operation deletes [key].
  bool get isDelete => value == null;
}

/// A key/value pair yielded by [StorageEngine.scan].
final class KeyValue {
  /// Creates a key/value pair.
  const KeyValue(this.key, this.value);

  /// The key bytes.
  final Uint8List key;

  /// The value bytes. May be empty; never represents a tombstone.
  final Uint8List value;
}

/// Point-in-time counters describing engine state.
final class StorageStats {
  /// Creates a stats snapshot.
  const StorageStats({
    required this.memtableEntries,
    required this.memtableSizeBytes,
    required this.immutableMemtableCount,
    required this.sstableCount,
    required this.sstableSizeBytes,
    required this.levelTableCounts,
    required this.lastSequenceNumber,
  });

  /// Entries (including tombstones) in the active memtable.
  final int memtableEntries;

  /// Approximate bytes held by the active memtable.
  final int memtableSizeBytes;

  /// Memtables sealed but not yet flushed to disk.
  final int immutableMemtableCount;

  /// Total SSTables across all levels.
  final int sstableCount;

  /// Total bytes of SSTable data across all levels.
  final int sstableSizeBytes;

  /// Number of SSTables per level, index 0 first.
  final List<int> levelTableCounts;

  /// Highest write-ahead-log sequence number assigned.
  final int lastSequenceNumber;
}

/// Durable ordered key/value storage.
///
/// All methods throw `DatabaseClosedException` after [close]. Keys and values
/// are opaque byte strings; ordering is lexicographic by unsigned byte.
abstract interface class StorageEngine {
  /// Durably stores [key] = [value]. Zero-length values are legal data.
  Future<void> put(Uint8List key, Uint8List value);

  /// Returns the value for [key], or null if absent or deleted.
  Future<Uint8List?> get(Uint8List key);

  /// Durably deletes [key]. Deleting an absent key is a no-op.
  Future<void> delete(Uint8List key);

  /// Applies [ops] atomically: after a crash either all or none are visible.
  ///
  /// [transactionId] tags the batch's WAL records for diagnostics; atomicity
  /// holds regardless.
  Future<void> writeBatch(List<WriteOp> ops, {int? transactionId});

  /// Ordered iteration over live entries.
  ///
  /// [startKey] is inclusive and [endKey] exclusive; null means unbounded.
  /// [limit] caps the number of results. When [reverse] is true, iteration
  /// runs from high keys to low (bounds keep their meaning). Tombstones are
  /// honored and the newest version of each key wins.
  Stream<KeyValue> scan({
    Uint8List? startKey,
    Uint8List? endKey,
    int? limit,
    bool reverse = false,
  });

  /// Persists the active memtable to disk and checkpoints the WAL.
  Future<void> flush();

  /// Runs compaction until no level exceeds its size target.
  Future<void> compact();

  /// Flushes and closes the engine. Safe to call more than once.
  Future<void> close();

  /// Current engine counters.
  StorageStats get stats;
}
