import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/demo_scaffold.dart';

/// A plain Dart class stored in a typed collection.
///
/// No code generation and no base class: a collection converts with the
/// `fromJson` and `toJson` functions it is given.
@immutable
class Employee {
  /// Creates an employee.
  const Employee({
    required this.id,
    required this.name,
    required this.department,
    required this.salary,
    required this.hiredAt,
  });

  /// Rebuilds an employee from a stored document.
  factory Employee.fromJson(Map<String, dynamic> json) => Employee(
    id: json['id'] as String,
    name: json['name'] as String,
    department: json['department'] as String,
    salary: json['salary'] as int,
    hiredAt: DateTime.parse(json['hiredAt'] as String),
  );

  /// Document id within the collection.
  final String id;

  /// Full name.
  final String name;

  /// Department the employee belongs to.
  final String department;

  /// Annual salary, in whole currency units.
  final int salary;

  /// When the employee was hired.
  final DateTime hiredAt;

  /// Converts this employee into a storable document.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'department': department,
    'salary': salary,
    'hiredAt': hiredAt.toIso8601String(),
  };
}

/// Stores a Dart class in a typed collection, indexes it and queries it.
class CollectionDemoScreen extends StatelessWidget {
  /// Creates the typed collection demo.
  const CollectionDemoScreen({super.key});

  static const String _snippet = '''
final employees = db.collection<Employee>(
  'employees',
  fromJson: Employee.fromJson,
  toJson: (e) => e.toJson(),
);

await employees.createIndex(['department', 'salary']);  // compound
await employees.put(e.id, e);

final paid = await employees.find((q) => q
    .whereEquals('department', 'Engineering')
    .whereGreaterThanOrEqual('salary', 90000)
    .orderBy('salary', descending: true));

employees.watch().listen((change) => reload());
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Typed collections',
      description:
          'A typed collection stores ordinary documents under "employees:id", '
          'so it shares indexes, queries and change streams with untyped '
          'access. The filter below is served by a compound index on '
          '(department, salary).',
      snippet: _snippet,
      scrollable: false,
      open: () => DatabaseService.open('collections'),
      builder: (BuildContext context, ReaxDB db) => _CollectionBody(db: db),
    );
  }
}

class _CollectionBody extends StatefulWidget {
  const _CollectionBody({required this.db});

  final ReaxDB db;

  @override
  State<_CollectionBody> createState() => _CollectionBodyState();
}

class _CollectionBodyState extends State<_CollectionBody> {
  static const List<String> _departments = <String>[
    'Engineering',
    'Design',
    'Support',
  ];
  static const List<String> _names = <String>[
    'Ada Lovelace',
    'Grace Hopper',
    'Alan Turing',
    'Barbara Liskov',
    'Ken Thompson',
    'Radia Perlman',
    'Edsger Dijkstra',
    'Frances Allen',
  ];

  final Random _random = Random();

  late final ReaxCollection<Employee> _employees = widget.db
      .collection<Employee>(
        'employees',
        fromJson: Employee.fromJson,
        toJson: (Employee e) => e.toJson(),
      );

  StreamSubscription<CollectionChange<Employee>>? _subscription;
  List<Employee> _results = <Employee>[];
  String? _department;
  int _minimumSalary = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // Creating an index backfills it from the documents already stored, so it
    // is safe to call on every open.
    await _employees.createIndex(<String>['department', 'salary']);
    _subscription = _employees.watch().listen(
      (CollectionChange<Employee> _) => _reload(),
    );
    if (!mounted) return;
    setState(() => _ready = true);
    await _reload();
  }

  Future<void> _reload() async {
    final List<Employee> results = await _employees.find((QueryBuilder query) {
      if (_department != null) query.whereEquals('department', _department);
      if (_minimumSalary > 0) {
        query.whereGreaterThanOrEqual('salary', _minimumSalary);
      }
      query.orderBy('salary', descending: true);
    });
    if (!mounted) return;
    setState(() => _results = results);
  }

  Future<void> _addRandom() async {
    final String id = DateTime.now().microsecondsSinceEpoch.toString();
    await _employees.put(
      id,
      Employee(
        id: id,
        name: _names[_random.nextInt(_names.length)],
        department: _departments[_random.nextInt(_departments.length)],
        salary: 60000 + _random.nextInt(80) * 1000,
        hiredAt: DateTime.now(),
      ),
    );
  }

  Future<void> _clear() async {
    await widget.db.query('employees').delete();
    await _reload();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              ChoiceChip(
                label: const Text('All'),
                selected: _department == null,
                onSelected: (_) {
                  setState(() => _department = null);
                  _reload();
                },
              ),
              for (final String department in _departments)
                ChoiceChip(
                  label: Text(department),
                  selected: _department == department,
                  onSelected: (_) {
                    setState(() => _department = department);
                    _reload();
                  },
                ),
              FilterChip(
                label: const Text('Salary >= 90k'),
                selected: _minimumSalary > 0,
                onSelected: (bool selected) {
                  setState(() => _minimumSalary = selected ? 90000 : 0);
                  _reload();
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              ActionButton(
                label: 'Hire someone',
                icon: Icons.person_add_alt,
                onPressed: _addRandom,
              ),
              ActionButton(
                label: 'Clear',
                icon: Icons.delete_outline,
                tonal: true,
                onPressed: _clear,
              ),
              Text(
                '${_results.length} matches',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _results.isEmpty
                  ? const Center(
                    child: Text('No employees match. Hire someone first.'),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _results.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Employee employee = _results[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(employee.name.characters.first),
                          ),
                          title: Text(employee.name),
                          subtitle: Text(
                            '${employee.department} — hired '
                            '${employee.hiredAt.toIso8601String().substring(0, 10)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '${(employee.salary / 1000).round()}k',
                                style: theme.textTheme.titleMedium,
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _employees.delete(employee.id),
                              ),
                            ],
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
