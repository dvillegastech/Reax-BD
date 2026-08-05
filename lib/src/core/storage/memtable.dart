/// Sorted in-memory write buffer.
library;

import 'dart:collection';
import 'dart:typed_data';

import '../util/byte_key.dart';

/// A value slot in the memtable.
///
/// Distinguishes "key present with a value" from "key present as a
/// tombstone"; absence is represented by [MemTable.lookup] returning null.
final class MemTableValue {
  /// Creates a live value slot.
  const MemTableValue(this.value);

  /// Creates a tombstone slot.
  const MemTableValue.tombstone() : value = null;

  /// The stored bytes, or null when this slot is a tombstone. A zero-length
  /// value is legitimate data.
  final Uint8List? value;

  /// Whether this slot marks a deletion.
  bool get isTombstone => value == null;
}

/// Sorted in-memory table buffering writes before they are flushed to an
/// SSTable. Tombstone-aware: deletions are stored explicitly so they can
/// shadow older on-disk versions.
final class MemTable {
  /// Creates a memtable that reports [isFull] once its content reaches
  /// [maxSizeBytes].
  MemTable({required this.maxSizeBytes});

  /// Approximate per-entry bookkeeping overhead in bytes.
  static const int entryOverheadBytes = 40;

  /// Size threshold at which the table should be flushed.
  final int maxSizeBytes;

  final SplayTreeMap<ByteKey, MemTableValue> _entries = SplayTreeMap();
  int _sizeBytes = 0;

  /// Stores [key] = [value], replacing any previous slot.
  void put(Uint8List key, Uint8List value) {
    _set(ByteKey(key), MemTableValue(value));
  }

  /// Records a tombstone for [key].
  void delete(Uint8List key) {
    _set(ByteKey(key), const MemTableValue.tombstone());
  }

  void _set(ByteKey key, MemTableValue slot) {
    final old = _entries[key];
    if (old != null) {
      _sizeBytes -= _slotSize(key, old);
    }
    _entries[key] = slot;
    _sizeBytes += _slotSize(key, slot);
  }

  static int _slotSize(ByteKey key, MemTableValue slot) =>
      key.bytes.length + (slot.value?.length ?? 0) + entryOverheadBytes;

  /// Looks up [key].
  ///
  /// Returns null when the key is absent from this table, a tombstone slot
  /// when it was deleted here, or a live slot with its value.
  MemTableValue? lookup(Uint8List key) => _entries[ByteKey(key)];

  /// All slots (including tombstones) in ascending key order.
  Iterable<MapEntry<ByteKey, MemTableValue>> get entries => _entries.entries;

  /// Slots within [start] (inclusive) and [end] (exclusive), ascending.
  Iterable<MapEntry<ByteKey, MemTableValue>> range(
    ByteKey? start,
    ByteKey? end,
  ) sync* {
    for (final e in _entries.entries) {
      if (start != null && e.key.compareTo(start) < 0) continue;
      if (end != null && e.key.compareTo(end) >= 0) break;
      yield e;
    }
  }

  /// Number of slots, tombstones included.
  int get entryCount => _entries.length;

  /// Approximate bytes held, including tombstone bookkeeping.
  int get sizeBytes => _sizeBytes;

  /// Whether the table has reached [maxSizeBytes].
  bool get isFull => _sizeBytes >= maxSizeBytes;

  /// Whether the table holds no slots at all.
  bool get isEmpty => _entries.isEmpty;
}
