import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';

/// Entries that expire on their own.
class TtlDemoScreen extends StatelessWidget {
  /// Creates the TTL demo.
  const TtlDemoScreen({super.key});

  static const String _snippet = '''
await db.put('session:abc', token, ttl: const Duration(seconds: 20));
await db.put('promo', banner, expiresAt: DateTime(2026, 1, 1));

// An expired entry reads as absent and iteration skips it.
final token = await db.get<String>('session:abc');  // null once expired

// Reclaim the space of everything already expired.
final reclaimed = await db.purgeExpired();
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Expiring entries',
      description:
          'An entry with a TTL reads as absent the moment it expires: get '
          'returns null, exists returns false and scans skip it. The space is '
          'reclaimed lazily on the next read of that key, or eagerly with '
          'purgeExpired.',
      snippet: _snippet,
      open: () => DatabaseService.open('ttl'),
      builder: (BuildContext context, ReaxDB db) => _TtlBody(db: db),
    );
  }
}

class _TtlBody extends StatefulWidget {
  const _TtlBody({required this.db});

  final ReaxDB db;

  @override
  State<_TtlBody> createState() => _TtlBodyState();
}

class _TtlBodyState extends State<_TtlBody> {
  final ConsoleController _console = ConsoleController();

  Timer? _ticker;
  List<ReaxEntry<Map<String, dynamic>>> _live =
      <ReaxEntry<Map<String, dynamic>>>[];
  int _counter = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _console.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (widget.db.isClosed) return;
    final List<ReaxEntry<Map<String, dynamic>>> live =
        await widget.db.scanPrefix<Map<String, dynamic>>('session:').toList();
    if (!mounted) return;
    setState(() => _live = live);
  }

  Future<void> _add(Duration ttl) async {
    final String key = 'session:${(++_counter).toString().padLeft(3, '0')}';
    await widget.db.put(key, <String, dynamic>{
      'user': 'user-$_counter',
      'issuedAt': DateTime.now().toIso8601String(),
    }, ttl: ttl);
    _console.success('put $key with ttl ${ttl.inSeconds}s');
    await _refresh();
  }

  Future<void> _readExpired() async {
    _console.section('Reading an entry that has already expired');
    const String key = 'session:probe';
    await widget.db.put(key, <String, dynamic>{
      'note': 'expires immediately',
    }, ttl: const Duration(milliseconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final Map<String, dynamic>? value = await widget.db
        .get<Map<String, dynamic>>(key);
    final bool exists = await widget.db.exists(key);
    _console.info('get -> $value');
    _console.info('exists -> $exists');
    _console.success(
      'The read reclaimed the entry through the write pipeline, so a delete '
      'event was published for it.',
    );
    await _refresh();
  }

  Future<void> _purge() async {
    final int reclaimed = await widget.db.purgeExpired();
    _console.success('purgeExpired() reclaimed $reclaimed entries.');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ActionButton(
              label: 'Session, 10s',
              icon: Icons.timer_outlined,
              onPressed: () => _add(const Duration(seconds: 10)),
            ),
            ActionButton(
              label: 'Session, 30s',
              icon: Icons.timer_outlined,
              tonal: true,
              onPressed: () => _add(const Duration(seconds: 30)),
            ),
            ActionButton(
              label: 'Read an expired key',
              icon: Icons.visibility_off_outlined,
              tonal: true,
              onPressed: _readExpired,
            ),
            ActionButton(
              label: 'purgeExpired',
              icon: Icons.cleaning_services_outlined,
              tonal: true,
              onPressed: _purge,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Live sessions', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_live.isEmpty)
                  Text(
                    'Nothing live. Add a session above and watch it disappear.',
                    style: theme.textTheme.bodySmall,
                  )
                else
                  for (final ReaxEntry<Map<String, dynamic>> entry in _live)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              entry.key,
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                          ),
                          Text(
                            entry.expiresAt == null
                                ? 'no expiry'
                                : '${entry.expiresAt!.difference(now).inSeconds}s left',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ConsoleWidget(controller: _console, height: 200),
      ],
    );
  }
}
