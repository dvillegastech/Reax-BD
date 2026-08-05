import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/demo_scaffold.dart';

/// The small key/value API: [SimpleReaxDB].
class SimpleDemoScreen extends StatefulWidget {
  /// Creates the key/value demo.
  const SimpleDemoScreen({super.key});

  @override
  State<SimpleDemoScreen> createState() => _SimpleDemoScreenState();
}

class _SimpleDemoScreenState extends State<SimpleDemoScreen> {
  static const String _snippet = '''
final db = await ReaxDB.simple('basics', path: dbPath);

await db.put('user:1', {'name': 'Ada'});
await db.putAll({'counter': 42, 'settings': {'theme': 'dark'}});

final user = await db.get('user:1');
final users = await db.getAll('user:*');   // pattern query
await db.delete('user:1');

db.watch('*').listen((event) => reload());
''';

  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  SimpleReaxDB? _db;
  StreamSubscription<DatabaseChangeEvent>? _subscription;
  Object? _error;
  List<MapEntry<String, Object?>> _entries = <MapEntry<String, Object?>>[];

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      // ReaxDB 2.0 never derives an encryption key from the database name.
      // Pass an EncryptionConfig if these values need to be encrypted.
      final SimpleReaxDB db = await DatabaseService.openSimple('basics');
      if (!mounted) {
        await db.close();
        return;
      }
      _subscription = db.watch().listen((DatabaseChangeEvent _) => _reload());
      setState(() => _db = db);
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _reload() async {
    final SimpleReaxDB? db = _db;
    if (db == null) return;
    final Map<String, Object?> all = await db.getAll('*');
    if (!mounted) return;
    setState(() {
      _entries =
          all.entries.toList()..sort(
            (MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
                a.key.compareTo(b.key),
          );
    });
  }

  /// Parses the text field the way a person would expect: JSON when it looks
  /// like JSON, otherwise a bool, a number, or a plain string.
  static Object? _parseValue(String raw) {
    if (raw.startsWith('{') || raw.startsWith('[')) {
      try {
        return jsonDecode(raw);
      } on FormatException {
        return raw;
      }
    }
    if (raw == 'true' || raw == 'false') return raw == 'true';
    return int.tryParse(raw) ?? double.tryParse(raw) ?? raw;
  }

  Future<void> _add() async {
    final SimpleReaxDB? db = _db;
    final String key = _keyController.text.trim();
    if (db == null || key.isEmpty) return;
    try {
      await db.put(key, _parseValue(_valueController.text));
      _keyController.clear();
      _valueController.clear();
    } on ReaxDbException catch (error) {
      _showError(error);
    }
  }

  Future<void> _addSamples() async {
    await _db?.putAll(<String, Object?>{
      'user:1': <String, dynamic>{'name': 'Ada', 'age': 36},
      'user:2': <String, dynamic>{'name': 'Grace', 'age': 45},
      'settings': <String, dynamic>{'theme': 'dark', 'notifications': true},
      'counter': 42,
    });
  }

  void _showError(ReaxDbException error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${error.runtimeType}: ${error.message}')),
    );
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    _subscription?.cancel();
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Object? error = _error;
    if (error != null) {
      return DemoScaffold(
        title: 'Key/value basics',
        description: _description,
        snippet: _snippet,
        child: ErrorCard(error: error),
      );
    }
    if (_db == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Key/value basics')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return DemoScaffold(
      title: 'Key/value basics',
      description: _description,
      snippet: _snippet,
      scrollable: false,
      actions: <Widget>[
        IconButton(
          onPressed: _addSamples,
          icon: const Icon(Icons.playlist_add),
          tooltip: 'Insert sample entries',
        ),
        IconButton(
          onPressed: () => _db?.clear(),
          icon: const Icon(Icons.delete_sweep_outlined),
          tooltip: 'Delete every entry',
        ),
      ],
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _keyController,
                    decoration: const InputDecoration(
                      labelText: 'Key',
                      helperText: 'for example user:3',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _valueController,
                    decoration: const InputDecoration(
                      labelText: 'Value',
                      helperText: 'text, number, bool or JSON',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: ActionButton(
                    label: 'Put',
                    icon: Icons.add,
                    onPressed: _add,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                _entries.isEmpty
                    ? const Center(
                      child: Text('No entries yet. Add one above.'),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: _entries.length,
                      itemBuilder: (BuildContext context, int index) {
                        final MapEntry<String, Object?> entry = _entries[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(entry.key),
                            subtitle: Text(
                              entry.value is Map || entry.value is List
                                  ? jsonEncode(entry.value)
                                  : '${entry.value}',
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _db?.delete(entry.key),
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  static const String _description =
      'SimpleReaxDB covers plain key/value use: put, get, delete, pattern '
      'queries and change streams. Anything beyond that is one property away '
      'on db.advanced.';
}
