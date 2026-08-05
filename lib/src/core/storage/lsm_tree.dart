/// Leveled LSM tree over immutable SSTables.
///
/// Level 0 holds memtable flushes whose key ranges may overlap; newer L0
/// tables shadow older ones. Levels 1 and deeper hold non-overlapping tables
/// ordered by key range. Compaction merges a level's tables with the
/// overlapping tables of the next level; tombstones are dropped only when
/// writing into the bottom level. All membership changes go through the
/// crash-atomic [Manifest]; files superseded by a compaction are kept on
/// disk until [close] (so concurrent readers are never broken) and any
/// leftovers are removed as orphans on the next open.
///
/// Compaction policy: L0 compacts when it has [LsmTree.l0CompactionTrigger]
/// tables; level N (N >= 1) compacts when its total bytes exceed
/// `baseLevelTargetBytes * levelSizeMultiplier^(N-1)`. Merged output is split
/// into tables of about [LsmTree.targetTableBytes].
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors/exceptions.dart';
import '../util/byte_key.dart';
import 'manifest.dart';
import 'sstable.dart';

final class _TableHandle {
  _TableHandle(this.id, this.table);

  final int id;
  final SSTable table;
}

/// Leveled collection of SSTables with crash-atomic membership.
final class LsmTree {
  LsmTree._(
    this._directory,
    this._manifest,
    this._levels, {
    required this.maxLevels,
    required this.l0CompactionTrigger,
    required this.baseLevelTargetBytes,
    required this.levelSizeMultiplier,
    required this.targetTableBytes,
  });

  final String _directory;
  final Manifest _manifest;

  /// `_levels[0]` is L0 ordered oldest to newest; deeper levels are ordered
  /// by ascending minimum key and never overlap internally.
  final List<List<_TableHandle>> _levels;

  /// Deepest allowed level index + 1.
  final int maxLevels;

  /// Number of L0 tables that triggers compaction into L1.
  final int l0CompactionTrigger;

  /// Size target for L1; deeper levels multiply by [levelSizeMultiplier].
  final int baseLevelTargetBytes;

  /// Growth factor between consecutive level size targets.
  final int levelSizeMultiplier;

  /// Approximate maximum size of a single compacted table.
  final int targetTableBytes;

  final List<_TableHandle> _obsolete = [];
  bool _closed = false;

  /// Opens the tree stored in [directory].
  ///
  /// Tables referenced by the manifest are opened and validated; `.sst` and
  /// `.sst.tmp` files not referenced by the manifest (leftovers of an
  /// interrupted flush or compaction) are deleted.
  static Future<LsmTree> open({
    required String directory,
    int maxLevels = 4,
    int l0CompactionTrigger = 4,
    int baseLevelTargetBytes = 8 * 1024 * 1024,
    int levelSizeMultiplier = 10,
    int targetTableBytes = 2 * 1024 * 1024,
  }) async {
    await Directory(directory).create(recursive: true);
    final manifest = await Manifest.open(directory);
    final referenced = manifest.state.allTableIds;

    // Remove orphans before opening anything.
    await for (final e in Directory(directory).list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.sst.tmp')) {
        await e.delete();
      } else if (name.endsWith('.sst')) {
        final id = _tableIdOf(name);
        if (id == null || !referenced.contains(id)) await e.delete();
      }
    }

    final levels = <List<_TableHandle>>[];
    for (final levelIds in manifest.state.levels) {
      final handles = <_TableHandle>[];
      for (final id in levelIds) {
        final table = await SSTable.open(
          p.join(directory, Manifest.tableFileName(id)),
        );
        handles.add(_TableHandle(id, table));
      }
      levels.add(handles);
    }
    return LsmTree._(
      directory,
      manifest,
      levels,
      maxLevels: maxLevels,
      l0CompactionTrigger: l0CompactionTrigger,
      baseLevelTargetBytes: baseLevelTargetBytes,
      levelSizeMultiplier: levelSizeMultiplier,
      targetTableBytes: targetTableBytes,
    );
  }

  static int? _tableIdOf(String name) {
    if (!name.startsWith('sst-') || !name.endsWith('.sst')) return null;
    return int.tryParse(name.substring(4, name.length - 4));
  }

  void _ensureOpen() {
    if (_closed) throw const DatabaseClosedException('LSM tree is closed');
  }

  /// Number of tables per level.
  List<int> get levelTableCounts => [for (final l in _levels) l.length];

  /// Total number of tables.
  int get tableCount => _levels.fold(0, (sum, level) => sum + level.length);

  /// Total bytes across all live tables.
  int get totalSizeBytes => _levels.fold(
    0,
    (sum, level) => sum + level.fold(0, (s, h) => s + h.table.fileSizeBytes),
  );

  /// Writes [entries] (sorted ascending, unique, tombstones included) as a
  /// new L0 table and registers it in the manifest.
  Future<void> addFlushedTable(List<SSTableEntry> entries) async {
    _ensureOpen();
    if (entries.isEmpty) return;
    final id = _manifest.state.nextTableId;
    final table = await SSTable.create(
      filePath: p.join(_directory, Manifest.tableFileName(id)),
      entries: entries,
    );
    while (_levels.isEmpty) {
      _levels.add([]);
    }
    _levels[0].add(_TableHandle(id, table));
    await _publishManifest(nextTableId: id + 1);
  }

  Future<void> _publishManifest({int? nextTableId}) async {
    await _manifest.update(
      ManifestState(
        nextTableId: nextTableId ?? _manifest.state.nextTableId,
        levels: [
          for (final level in _levels) [for (final h in level) h.id],
        ],
      ),
    );
  }

  /// Looks up [key] across all levels, newest version first.
  ///
  /// Returns null if the key is in no table; a tombstone entry if the newest
  /// version is a deletion.
  Future<SSTableEntry?> get(Uint8List key) async {
    _ensureOpen();
    if (_levels.isNotEmpty) {
      for (final h in _levels[0].reversed) {
        final e = await h.table.get(key);
        if (e != null) return e;
      }
    }
    for (var l = 1; l < _levels.length; l++) {
      for (final h in _levels[l]) {
        if (ByteKey.compareBytes(key, h.table.minKey) < 0 ||
            ByteKey.compareBytes(key, h.table.maxKey) > 0) {
          continue;
        }
        final e = await h.table.get(key);
        if (e != null) return e;
      }
    }
    return null;
  }

  /// Merged, ordered iteration across every level.
  ///
  /// Yields at most one entry per key (newest wins) and includes tombstones
  /// so the caller can mask memtable-shadowed and deleted keys. [startKey]
  /// inclusive, [endKey] exclusive, [reverse] flips direction.
  Stream<SSTableEntry> scan({
    Uint8List? startKey,
    Uint8List? endKey,
    bool reverse = false,
  }) {
    _ensureOpen();
    final sources = <Stream<SSTableEntry>>[];
    // Lower source index = higher priority (newer data).
    if (_levels.isNotEmpty) {
      for (final h in _levels[0].reversed) {
        sources.add(
          h.table.range(startKey: startKey, endKey: endKey, reverse: reverse),
        );
      }
    }
    for (var l = 1; l < _levels.length; l++) {
      final ordered = reverse ? _levels[l].reversed : _levels[l];
      sources.add(
        _concat([
          for (final h in ordered)
            h.table.range(startKey: startKey, endKey: endKey, reverse: reverse),
        ]),
      );
    }
    return mergeEntryStreams(sources, reverse: reverse);
  }

  static Stream<SSTableEntry> _concat(
    List<Stream<SSTableEntry>> streams,
  ) async* {
    for (final s in streams) {
      yield* s;
    }
  }

  /// K-way merge of ordered entry streams.
  ///
  /// Earlier streams in [sources] take priority when keys collide (their
  /// entry wins and later streams' duplicates are skipped). Streams must be
  /// ordered ascending, or descending when [reverse] is true.
  static Stream<SSTableEntry> mergeEntryStreams(
    List<Stream<SSTableEntry>> sources, {
    bool reverse = false,
  }) async* {
    final iterators = [for (final s in sources) StreamIterator(s)];
    final current = List<SSTableEntry?>.filled(iterators.length, null);
    try {
      for (var i = 0; i < iterators.length; i++) {
        if (await iterators[i].moveNext()) current[i] = iterators[i].current;
      }
      while (true) {
        Uint8List? best;
        for (final e in current) {
          if (e == null) continue;
          if (best == null) {
            best = e.key;
            continue;
          }
          final cmp = ByteKey.compareBytes(e.key, best);
          if (reverse ? cmp > 0 : cmp < 0) best = e.key;
        }
        if (best == null) return;
        SSTableEntry? winner;
        for (var i = 0; i < current.length; i++) {
          final e = current[i];
          if (e == null || ByteKey.compareBytes(e.key, best) != 0) continue;
          winner ??= e; // First (highest-priority) source wins.
          current[i] =
              await iterators[i].moveNext() ? iterators[i].current : null;
        }
        yield winner!;
      }
    } finally {
      for (final it in iterators) {
        await it.cancel();
      }
    }
  }

  int _levelTargetBytes(int level) {
    var target = baseLevelTargetBytes;
    for (var i = 1; i < level; i++) {
      target *= levelSizeMultiplier;
    }
    return target;
  }

  int _levelBytes(int level) =>
      _levels[level].fold(0, (s, h) => s + h.table.fileSizeBytes);

  /// Index of the shallowest level that needs compaction, or null.
  int? get _compactionCandidate {
    if (_levels.isNotEmpty && _levels[0].length >= l0CompactionTrigger) {
      return 0;
    }
    for (var l = 1; l < _levels.length && l < maxLevels - 1; l++) {
      if (_levelBytes(l) > _levelTargetBytes(l)) return l;
    }
    return null;
  }

  /// Whether [compact] currently has work to do.
  bool get needsCompaction => _compactionCandidate != null;

  /// Runs compaction rounds until no level exceeds its target.
  ///
  /// When [force] is true, L0 is compacted into L1 even below the trigger
  /// threshold before the normal policy loop runs.
  Future<void> compact({bool force = false}) async {
    _ensureOpen();
    if (force && _levels.isNotEmpty && _levels[0].isNotEmpty) {
      await _compactLevel(0);
    }
    while (true) {
      final level = _compactionCandidate;
      if (level == null) return;
      await _compactLevel(level);
    }
  }

  Future<void> _compactLevel(int sourceLevel) async {
    final targetLevel = sourceLevel + 1;
    while (_levels.length <= targetLevel) {
      _levels.add([]);
    }

    // Source tables: all of L0, or one table from deeper levels.
    final List<_TableHandle> sourceTables =
        sourceLevel == 0 ? List.of(_levels[0]) : [_levels[sourceLevel].first];

    Uint8List? minKey;
    Uint8List? maxKey;
    for (final h in sourceTables) {
      if (minKey == null || ByteKey.compareBytes(h.table.minKey, minKey) < 0) {
        minKey = h.table.minKey;
      }
      if (maxKey == null || ByteKey.compareBytes(h.table.maxKey, maxKey) > 0) {
        maxKey = h.table.maxKey;
      }
    }

    final overlapping = <_TableHandle>[
      for (final h in _levels[targetLevel])
        if (ByteKey.compareBytes(h.table.maxKey, minKey!) >= 0 &&
            ByteKey.compareBytes(h.table.minKey, maxKey!) <= 0)
          h,
    ];

    // Newest first: L0 newest table has priority, then older, then target.
    final sources = <Stream<SSTableEntry>>[
      for (final h in sourceTables.reversed) h.table.scanAll(),
      for (final h in overlapping) h.table.scanAll(),
    ];
    final dropTombstones = targetLevel >= maxLevels - 1;

    final newHandles = <_TableHandle>[];
    var nextId = _manifest.state.nextTableId;
    var pending = <SSTableEntry>[];
    var pendingBytes = 0;

    Future<void> flushPending() async {
      if (pending.isEmpty) return;
      final id = nextId++;
      final table = await SSTable.create(
        filePath: p.join(_directory, Manifest.tableFileName(id)),
        entries: pending,
      );
      newHandles.add(_TableHandle(id, table));
      pending = <SSTableEntry>[];
      pendingBytes = 0;
    }

    await for (final e in mergeEntryStreams(sources)) {
      if (dropTombstones && e.isTombstone) continue;
      pending.add(e);
      pendingBytes += e.key.length + (e.value?.length ?? 0) + 32;
      if (pendingBytes >= targetTableBytes) await flushPending();
    }
    await flushPending();

    // Swap membership in memory, then publish atomically.
    final removedIds = {
      for (final h in sourceTables) h.id,
      for (final h in overlapping) h.id,
    };
    if (sourceLevel == 0) {
      _levels[0].clear();
    } else {
      _levels[sourceLevel].removeWhere((h) => removedIds.contains(h.id));
    }
    _levels[targetLevel]
      ..removeWhere((h) => removedIds.contains(h.id))
      ..addAll(newHandles)
      ..sort((a, b) => ByteKey.compareBytes(a.table.minKey, b.table.minKey));
    while (_levels.isNotEmpty && _levels.last.isEmpty) {
      _levels.removeLast();
    }
    await _publishManifest(nextTableId: nextId);

    // Superseded files stay on disk until close so concurrent readers keep
    // working; they are orphan-cleaned on the next open as well.
    _obsolete
      ..addAll(sourceTables)
      ..addAll(overlapping);
  }

  /// Closes every table and deletes files superseded by compaction.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final level in _levels) {
      for (final h in level) {
        await h.table.close();
      }
    }
    for (final h in _obsolete) {
      await h.table.close();
      final f = File(h.table.path);
      if (await f.exists()) await f.delete();
    }
    _obsolete.clear();
  }
}
