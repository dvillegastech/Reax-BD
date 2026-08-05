import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';
import '../widgets/stats_card.dart';

/// Shows what an open database reports about itself, plus the two maintenance
/// operations and a real schema migration.
class OverviewScreen extends StatelessWidget {
  /// Creates the overview screen.
  const OverviewScreen({super.key});

  static const String _snippet = '''
final db = await ReaxDB.open(path: '\$documents/reaxdb_example/overview');

final DatabaseInfo info = await db.info();
final CacheStatistics cache = db.cacheStats;
final StorageStats storage = db.storageStats;

await db.flush();    // seal the memtable, checkpoint the WAL
await db.compact();  // reclaim space from overwritten keys
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Overview',
      description:
          'Everything an open ReaxDB database reports about itself. The '
          'counters below are live: write some entries and watch the memtable '
          'grow, then flush and compact to move them onto disk.',
      snippet: _snippet,
      open: () => DatabaseService.open('overview'),
      builder: (BuildContext context, ReaxDB db) => _OverviewBody(db: db),
    );
  }
}

class _OverviewBody extends StatefulWidget {
  const _OverviewBody({required this.db});

  final ReaxDB db;

  @override
  State<_OverviewBody> createState() => _OverviewBodyState();
}

class _OverviewBodyState extends State<_OverviewBody> {
  final ConsoleController _console = ConsoleController();

  DatabaseInfo? _info;
  Map<String, dynamic> _statistics = const <String, dynamic>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on ReaxDbException catch (error) {
      _console.failure(
        '$label failed: ${error.runtimeType} — ${error.message}',
      );
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (widget.db.isClosed) return;
    final DatabaseInfo info = await widget.db.info();
    final Map<String, dynamic> statistics = widget.db.statistics();
    if (!mounted) return;
    setState(() {
      _info = info;
      _statistics = statistics;
    });
  }

  Future<void> _seed() => _run('Seed', () async {
    final Map<String, Object?> batch = <String, Object?>{
      for (int i = 0; i < 200; i++)
        'reading:${i.toString().padLeft(4, '0')}': <String, dynamic>{
          'sensor': 'sensor-${i % 8}',
          'celsius': 18 + (i % 15),
          'recordedAt': DateTime.now().toIso8601String(),
        },
    };
    await widget.db.putBatch(batch);
    _console.success('Wrote 200 entries in one atomic batch.');
    // Reading a key twice shows the cache serving the second lookup.
    await widget.db.get<Map<String, dynamic>>('reading:0000');
    await widget.db.get<Map<String, dynamic>>('reading:0000');
    final CacheStatistics cache = widget.db.cacheStats;
    _console.info(
      'Cache: ${cache.hits} hits, ${cache.misses} misses, '
      '${(cache.hitRatio * 100).toStringAsFixed(1)}% hit ratio.',
    );
  });

  Future<void> _flush() => _run('Flush', () async {
    await widget.db.flush();
    _console.success('Memtable flushed and the write-ahead log checkpointed.');
  });

  Future<void> _compact() => _run('Compact', () async {
    final int before = widget.db.storageStats.sstableSizeBytes;
    await widget.db.compact();
    final int after = widget.db.storageStats.sstableSizeBytes;
    _console.success(
      'Compacted: ${_bytes(before)} of tables became ${_bytes(after)}.',
    );
  });

  Future<void> _clear() => _run('Clear', () async {
    final List<String> keys = await widget.db.keys().toList();
    await widget.db.deleteBatch(keys);
    _console.success('Deleted ${keys.length} entries.');
  });

  /// Creates a scratch database at schema version 1, then reopens it at
  /// version 2 so [ReaxDB.open]'s `onUpgrade` callback actually runs.
  Future<void> _migrate() => _run('Migration', () async {
    const String name = 'overview_migration';
    _console.section('Schema migration');
    await DatabaseService.delete(name);

    final ReaxDB v1 = await DatabaseService.open(name);
    await v1.put('profile:1', <String, dynamic>{
      'name': 'Ada',
      'city': 'London',
    });
    _console.info('Created a database at schema version ${v1.schemaVersion}.');
    await v1.close();

    int migrated = 0;
    final ReaxDB v2 = await DatabaseService.open(
      name,
      schemaVersion: 2,
      onUpgrade: (int from, int to, ReaxDB db) async {
        _console.info('onUpgrade($from -> $to) running.');
        await for (final ReaxEntry<Map<String, dynamic>> entry in db
            .scanPrefix<Map<String, dynamic>>('profile:')) {
          await db.put(entry.key, <String, dynamic>{
            ...entry.value,
            'displayName': entry.value['name'],
            'schema': to,
          });
          migrated++;
        }
      },
    );
    final Map<String, dynamic>? profile = await v2.get<Map<String, dynamic>>(
      'profile:1',
    );
    _console.success(
      'Migrated $migrated document(s); the database now reports schema '
      'version ${v2.schemaVersion}.',
    );
    _console.info('profile:1 is now $profile');
    await v2.close();
    await DatabaseService.delete(name);
  });

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final DatabaseInfo? info = _info;
    final Map<String, dynamic> cache =
        (_statistics['cache'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final Map<String, dynamic> storage =
        (_statistics['storage'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (info != null) ...<Widget>[
          StatsCard(
            title: 'Database',
            stats: <Stat>[
              Stat('Entries', '${info.entryCount}'),
              Stat('On disk', _bytes(info.sizeBytes)),
              Stat('Indexes', '${info.indexCount}'),
              Stat('Schema', 'v${info.schemaVersion}'),
              Stat('Sync mode', info.syncMode),
              Stat('Encryption', info.encryptionType),
            ],
          ),
          const SizedBox(height: 8),
          StatsCard(
            title: 'Cache',
            stats: <Stat>[
              Stat('Entries', '${cache['entries'] ?? 0}'),
              Stat(
                'Hit ratio',
                '${(((cache['hitRatio'] as double?) ?? 0) * 100).toStringAsFixed(1)}%',
              ),
              Stat('Hits', '${cache['hits'] ?? 0}'),
              Stat('Misses', '${cache['misses'] ?? 0}'),
              Stat('Evictions', '${cache['evictions'] ?? 0}'),
              Stat('Memory', _bytes((cache['memoryBytes'] as int?) ?? 0)),
            ],
          ),
          const SizedBox(height: 8),
          StatsCard(
            title: 'Storage engine',
            stats: <Stat>[
              Stat('Memtable', '${storage['memtableEntries'] ?? 0} entries'),
              Stat(
                'Buffered',
                _bytes((storage['memtableSizeBytes'] as int?) ?? 0),
              ),
              Stat('SSTables', '${storage['sstableCount'] ?? 0}'),
              Stat('Sequence', '${storage['lastSequenceNumber'] ?? 0}'),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ActionButton(
              label: 'Write 200 entries',
              icon: Icons.add,
              onPressed: _busy ? null : _seed,
            ),
            ActionButton(
              label: 'Flush',
              icon: Icons.save_alt,
              tonal: true,
              onPressed: _busy ? null : _flush,
            ),
            ActionButton(
              label: 'Compact',
              icon: Icons.compress,
              tonal: true,
              onPressed: _busy ? null : _compact,
            ),
            ActionButton(
              label: 'Run a migration',
              icon: Icons.upgrade,
              tonal: true,
              onPressed: _busy ? null : _migrate,
            ),
            ActionButton(
              label: 'Delete all',
              icon: Icons.delete_outline,
              tonal: true,
              onPressed: _busy ? null : _clear,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ConsoleWidget(controller: _console),
      ],
    );
  }
}
