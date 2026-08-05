import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';

/// One measured run of the durability benchmark.
@immutable
class _Measurement {
  const _Measurement(this.mode, this.survives, this.microseconds, this.writes);

  final SyncMode mode;
  final String survives;
  final int microseconds;
  final int writes;

  double get writesPerSecond => writes / (microseconds / 1000000);

  double get microsecondsPerWrite => microseconds / writes;
}

/// Measures what each [SyncMode] costs on this device.
class DurabilityDemoScreen extends StatefulWidget {
  /// Creates the durability demo.
  const DurabilityDemoScreen({super.key});

  @override
  State<DurabilityDemoScreen> createState() => _DurabilityDemoScreenState();
}

class _DurabilityDemoScreenState extends State<DurabilityDemoScreen> {
  static const String _snippet = '''
// The database default applies to every write.
final db = await ReaxDB.open(path: dbPath, syncMode: SyncMode.os);

// A single write that must survive power loss can ask for more.
await db.put('payment:1', receipt, sync: SyncMode.full);
''';

  static const int _writes = 200;

  final ConsoleController _console = ConsoleController();
  final List<_Measurement> _measurements = <_Measurement>[];
  bool _busy = false;

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  Future<_Measurement> _measure(SyncMode mode, String survives) async {
    final String name = 'durability_${mode.name}';
    await DatabaseService.delete(name);
    final ReaxDB db = await DatabaseService.open(name, syncMode: mode);
    try {
      final Map<String, dynamic> payload = <String, dynamic>{
        'amount': 1999,
        'currency': 'EUR',
        'reference': 'a payment receipt of a realistic size',
      };
      final Stopwatch stopwatch = Stopwatch()..start();
      for (int i = 0; i < _writes; i++) {
        await db.put('payment:${i.toString().padLeft(4, '0')}', payload);
      }
      stopwatch.stop();
      return _Measurement(
        mode,
        survives,
        stopwatch.elapsedMicroseconds,
        _writes,
      );
    } finally {
      await db.close();
      await DatabaseService.delete(name);
    }
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _measurements.clear();
    });
    _console.section('$_writes sequential writes per mode');
    try {
      for (final (SyncMode mode, String survives) in const <(SyncMode, String)>[
        (SyncMode.none, 'nothing guaranteed'),
        (SyncMode.os, 'process kill'),
        (SyncMode.full, 'power loss'),
      ]) {
        final _Measurement measurement = await _measure(mode, survives);
        if (!mounted) return;
        setState(() => _measurements.add(measurement));
        _console.info(
          '${mode.name}: ${(measurement.microseconds / 1000).toStringAsFixed(1)} ms '
          'total, ${measurement.microsecondsPerWrite.toStringAsFixed(0)} us per write',
        );
      }
      _console.success(
        'Higher durability costs time because the write-ahead log is handed '
        'to the OS, or fsynced, before the write is acknowledged.',
      );
      _console.warning(
        'This measures the cost of durability, not durability itself: only '
        'killing the process or cutting power can demonstrate what each mode '
        'actually survives.',
      );
    } on ReaxDbException catch (error) {
      _console.failure('${error.runtimeType}: ${error.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _perWriteOverride() async {
    setState(() => _busy = true);
    const String name = 'durability_override';
    try {
      await DatabaseService.delete(name);
      final ReaxDB db = await DatabaseService.open(
        name,
        syncMode: SyncMode.none,
      );
      try {
        _console.section('Per-write override on a SyncMode.none database');
        final Stopwatch fast = Stopwatch()..start();
        await db.put('draft:1', 'saved as you type');
        fast.stop();
        final Stopwatch durable = Stopwatch()..start();
        await db.put('payment:1', 'must not be lost', sync: SyncMode.full);
        durable.stop();
        _console.info(
          'Default write: ${fast.elapsedMicroseconds} us. '
          'With sync: SyncMode.full: ${durable.elapsedMicroseconds} us.',
        );
        _console.success(
          'An override only ever strengthens durability; it cannot weaken the '
          'database default.',
        );
      } finally {
        await db.close();
        await DatabaseService.delete(name);
      }
    } on ReaxDbException catch (error) {
      _console.failure('${error.runtimeType}: ${error.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double slowest =
        _measurements.isEmpty
            ? 1
            : _measurements
                .map((_Measurement m) => m.microseconds)
                .reduce((int a, int b) => a > b ? a : b)
                .toDouble();

    return DemoScaffold(
      title: 'Durability modes',
      description:
          'An awaited write that returns normally is recoverable, to the '
          'extent the effective sync mode promises. The numbers below are '
          'measured on this device, right now, with $_writes sequential '
          'writes into a throwaway database per mode.',
      snippet: _snippet,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ActionButton(
                label: 'Measure the three modes',
                icon: Icons.timer_outlined,
                onPressed: _busy ? null : _run,
              ),
              ActionButton(
                label: 'Per-write override',
                icon: Icons.tune,
                tonal: true,
                onPressed: _busy ? null : _perWriteOverride,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_busy && _measurements.length < 3)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          for (final _Measurement measurement in _measurements)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          'SyncMode.${measurement.mode.name}',
                          style: theme.textTheme.titleMedium,
                        ),
                        const Spacer(),
                        Text(
                          '${measurement.writesPerSecond.toStringAsFixed(0)} writes/s',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Survives: ${measurement.survives} — '
                      '${measurement.microsecondsPerWrite.toStringAsFixed(0)} us per write',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: measurement.microseconds / slowest,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          ConsoleWidget(controller: _console, height: 220),
        ],
      ),
    );
  }
}
