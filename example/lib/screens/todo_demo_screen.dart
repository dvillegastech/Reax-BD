import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/demo_scaffold.dart';

/// A small application built on prefix scans and change streams.
class TodoDemoScreen extends StatelessWidget {
  /// Creates the todo demo.
  const TodoDemoScreen({super.key});

  static const String _snippet = '''
await db.put('todo:\$id', {'title': title, 'completed': false});

// Newest first: keys are time-ordered, so reverse iteration is the sort.
final todos = await db
    .scanPrefix<Map<String, dynamic>>('todo:', reverse: true)
    .toList();

// Every write publishes an event after its durability point.
_subscription = db.watchPrefix('todo:').listen((_) => reload());
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Todo list',
      description:
          'Todos are stored under the "todo:" prefix with a time-ordered key, '
          'so listing them newest-first is a reverse prefix scan. The list '
          'never reloads itself: it reloads when the database says something '
          'changed.',
      snippet: _snippet,
      scrollable: false,
      open: () => DatabaseService.open('todo'),
      builder: (BuildContext context, ReaxDB db) => _TodoBody(db: db),
    );
  }
}

class _TodoBody extends StatefulWidget {
  const _TodoBody({required this.db});

  final ReaxDB db;

  @override
  State<_TodoBody> createState() => _TodoBodyState();
}

class _TodoBodyState extends State<_TodoBody> {
  final TextEditingController _controller = TextEditingController();
  StreamSubscription<DatabaseChangeEvent>? _subscription;
  List<ReaxEntry<Map<String, dynamic>>> _todos =
      <ReaxEntry<Map<String, dynamic>>>[];

  @override
  void initState() {
    super.initState();
    _subscription = widget.db
        .watchPrefix('todo:')
        .listen((DatabaseChangeEvent _) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _controller.dispose();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (widget.db.isClosed) return;
    final List<ReaxEntry<Map<String, dynamic>>> todos =
        await widget.db
            .scanPrefix<Map<String, dynamic>>('todo:', reverse: true)
            .toList();
    if (!mounted) return;
    setState(() => _todos = todos);
  }

  Future<void> _add(String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    _controller.clear();
    await widget.db
        .put('todo:${DateTime.now().microsecondsSinceEpoch}', <String, dynamic>{
          'title': trimmed,
          'completed': false,
          'createdAt': DateTime.now().toIso8601String(),
        });
  }

  Future<void> _toggle(ReaxEntry<Map<String, dynamic>> todo) =>
      widget.db.put(todo.key, <String, dynamic>{
        ...todo.value,
        'completed': !(todo.value['completed'] as bool? ?? false),
      });

  @override
  Widget build(BuildContext context) {
    final int pending =
        _todos
            .where(
              (ReaxEntry<Map<String, dynamic>> t) =>
                  !(t.value['completed'] as bool? ?? false),
            )
            .length;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: 'What needs to be done?',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: _add,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _add(_controller.text),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$pending pending, ${_todos.length - pending} done',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed:
                    _todos.isEmpty
                        ? null
                        : () => widget.db.deleteBatch(<String>[
                          for (final ReaxEntry<Map<String, dynamic>> t
                              in _todos)
                            if (t.value['completed'] as bool? ?? false) t.key,
                        ]),
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear completed'),
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _todos.isEmpty
                  ? const Center(child: Text('Nothing to do yet.'))
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _todos.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ReaxEntry<Map<String, dynamic>> todo =
                          _todos[index];
                      final bool completed =
                          todo.value['completed'] as bool? ?? false;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Checkbox(
                            value: completed,
                            onChanged: (_) => _toggle(todo),
                          ),
                          title: Text(
                            todo.value['title'] as String? ?? '',
                            style: TextStyle(
                              decoration:
                                  completed ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          subtitle: Text(
                            todo.key,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => widget.db.delete(todo.key),
                          ),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}
