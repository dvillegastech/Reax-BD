import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';

/// Ordered iteration over the key space.
class IterationDemoScreen extends StatelessWidget {
  /// Creates the iteration demo.
  const IterationDemoScreen({super.key});

  static const String _snippet = '''
await for (final entry in db.scanPrefix<Map<String, dynamic>>('city:')) {
  print('\${entry.key} -> \${entry.value}');
}

await for (final key in db.keys(prefix: 'city:', limit: 5)) { ... }

final page = await db.range<Map<String, dynamic>>(
  'city:l', 'city:s', limit: 10,
);

final newest = await db.scan<Map<String, dynamic>>(
  startKey: 'city:', reverse: true, limit: 3,
).toList();
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Iteration and scans',
      description:
          'Iteration is backed by the storage engine\'s ordered, '
          'tombstone-aware merge scan. Keys come back in byte order, expired '
          'entries are skipped, and ReaxDB internal keys are never yielded.',
      snippet: _snippet,
      open: () => DatabaseService.open('iteration'),
      builder: (BuildContext context, ReaxDB db) => _IterationBody(db: db),
    );
  }
}

class _IterationBody extends StatefulWidget {
  const _IterationBody({required this.db});

  final ReaxDB db;

  @override
  State<_IterationBody> createState() => _IterationBodyState();
}

class _IterationBodyState extends State<_IterationBody> {
  static const Map<String, int> _cities = <String, int>{
    'amsterdam': 921402,
    'berlin': 3850809,
    'copenhagen': 653664,
    'dublin': 592713,
    'edinburgh': 506520,
    'lisbon': 545796,
    'london': 8866180,
    'madrid': 3223334,
    'oslo': 709037,
    'paris': 2102650,
    'prague': 1357326,
    'stockholm': 984748,
    'vienna': 2028399,
    'warsaw': 1863056,
  };

  final ConsoleController _console = ConsoleController();
  bool _busy = false;
  int _entryCount = 0;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on ReaxDbException catch (error) {
      _console.failure('${error.runtimeType}: ${error.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seed() => _run(() async {
    await widget.db.putBatch(<String, Object?>{
      for (final MapEntry<String, int> city in _cities.entries)
        'city:${city.key}': <String, dynamic>{
          'name': city.key,
          'population': city.value,
        },
      // A second key prefix, to show that prefix scans really are bounded.
      'country:ie': <String, dynamic>{'name': 'Ireland'},
      'country:pt': <String, dynamic>{'name': 'Portugal'},
    });
    final int count = await widget.db.keys().length;
    if (!mounted) return;
    setState(() => _entryCount = count);
    _console.success('Seeded ${_cities.length} cities and 2 countries.');
  });

  Future<void> _scanPrefix() => _run(() async {
    _console.section('scanPrefix("city:")');
    await for (final ReaxEntry<Map<String, dynamic>> entry in widget.db
        .scanPrefix<Map<String, dynamic>>('city:', limit: 6)) {
      _console.info('${entry.key} -> ${entry.value['population']}');
    }
    _console.success('Six entries, in key order, all under the prefix.');
  });

  Future<void> _keysOnly() => _run(() async {
    _console.section('keys(prefix: "country:")');
    final List<String> keys = await widget.db.keys(prefix: 'country:').toList();
    _console.info(keys.join('\n'));
    _console.success('${keys.length} keys, values never decoded.');
  });

  Future<void> _range() => _run(() async {
    _console.section('range("city:l", "city:s")');
    final List<ReaxEntry<Map<String, dynamic>>> page = await widget.db
        .range<Map<String, dynamic>>('city:l', 'city:s');
    for (final ReaxEntry<Map<String, dynamic>> entry in page) {
      _console.info(entry.key);
    }
    _console.success('${page.length} entries: start inclusive, end exclusive.');
  });

  Future<void> _reverse() => _run(() async {
    _console.section('scan(startKey: "city:", reverse: true, limit: 3)');
    final List<ReaxEntry<Map<String, dynamic>>> last =
        await widget.db
            .scan<Map<String, dynamic>>(
              startKey: 'city:',
              reverse: true,
              limit: 3,
            )
            .toList();
    for (final ReaxEntry<Map<String, dynamic>> entry in last) {
      _console.info(entry.key);
    }
    _console.success('The three highest keys, high to low.');
  });

  Future<void> _aggregate() => _run(() async {
    _console.section('Aggregating a scan in Dart');
    int total = 0;
    int biggest = 0;
    String biggestName = '';
    await for (final ReaxEntry<Map<String, dynamic>> entry in widget.db
        .scanPrefix<Map<String, dynamic>>('city:')) {
      final int population = entry.value['population'] as int;
      total += population;
      if (population > biggest) {
        biggest = population;
        biggestName = entry.value['name'] as String;
      }
    }
    _console.info('Total population: $total');
    _console.success('Largest: $biggestName ($biggest)');
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '$_entryCount entries in the database.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ActionButton(
              label: 'scanPrefix',
              icon: Icons.filter_list,
              onPressed: _busy ? null : _scanPrefix,
            ),
            ActionButton(
              label: 'keys',
              icon: Icons.key_outlined,
              tonal: true,
              onPressed: _busy ? null : _keysOnly,
            ),
            ActionButton(
              label: 'range',
              icon: Icons.linear_scale,
              tonal: true,
              onPressed: _busy ? null : _range,
            ),
            ActionButton(
              label: 'reverse + limit',
              icon: Icons.swap_vert,
              tonal: true,
              onPressed: _busy ? null : _reverse,
            ),
            ActionButton(
              label: 'aggregate',
              icon: Icons.functions,
              tonal: true,
              onPressed: _busy ? null : _aggregate,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ConsoleWidget(controller: _console, height: 320),
      ],
    );
  }
}
