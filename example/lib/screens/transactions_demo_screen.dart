import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';
import '../widgets/stats_card.dart';

/// Thrown by the demo transfer when an account cannot cover the amount.
class InsufficientFunds implements Exception {
  /// Creates the error for [account].
  const InsufficientFunds(this.account);

  /// The account that was short.
  final String account;

  @override
  String toString() => 'InsufficientFunds($account)';
}

/// Atomic transfers, rollback and compare-and-swap.
class TransactionsDemoScreen extends StatelessWidget {
  /// Creates the transactions demo.
  const TransactionsDemoScreen({super.key});

  static const String _snippet = '''
await db.transaction((tx) async {
  final from = await tx.get<Map<String, dynamic>>('account:checking');
  final to = await tx.get<Map<String, dynamic>>('account:savings');
  if ((from!['balance'] as int) < amount) {
    throw const InsufficientFunds('checking');  // aborts, nothing is written
  }
  await tx.put('account:checking', {...from, 'balance': from['balance'] - amount});
  await tx.put('account:savings', {...to!, 'balance': to['balance'] + amount});
}, isolationLevel: IsolationLevel.serializable);

final swapped = await db.compareAndSwap<int>('counter', 1, 2);
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Transactions',
      description:
          'The whole write set of a transaction is applied in one atomic '
          'batch. If the body throws, nothing is written at all. Conflicts '
          'and deadlocks are retried automatically, up to maxAttempts.',
      snippet: _snippet,
      open: () => DatabaseService.open('transactions'),
      builder: (BuildContext context, ReaxDB db) => _TransactionsBody(db: db),
    );
  }
}

class _TransactionsBody extends StatefulWidget {
  const _TransactionsBody({required this.db});

  final ReaxDB db;

  @override
  State<_TransactionsBody> createState() => _TransactionsBodyState();
}

class _TransactionsBodyState extends State<_TransactionsBody> {
  static const String _checking = 'account:checking';
  static const String _savings = 'account:savings';
  static const String _counter = 'counter';

  final ConsoleController _console = ConsoleController();

  int _checkingBalance = 0;
  int _savingsBalance = 0;
  int _counterValue = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reset();
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
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (widget.db.isClosed) return;
    final Map<String, dynamic>? checking = await widget.db
        .get<Map<String, dynamic>>(_checking);
    final Map<String, dynamic>? savings = await widget.db
        .get<Map<String, dynamic>>(_savings);
    final int counter = await widget.db.get<int>(_counter) ?? 0;
    if (!mounted) return;
    setState(() {
      _checkingBalance = (checking?['balance'] as int?) ?? 0;
      _savingsBalance = (savings?['balance'] as int?) ?? 0;
      _counterValue = counter;
    });
  }

  Future<void> _reset() => _run(() async {
    await widget.db.putBatch(<String, Object?>{
      _checking: <String, dynamic>{'owner': 'Ada', 'balance': 500},
      _savings: <String, dynamic>{'owner': 'Ada', 'balance': 1500},
      _counter: 0,
    });
    _console.success('Accounts reset to 500 and 1500.');
  });

  Future<void> _transfer(int amount) => _run(() async {
    try {
      await widget.db.transaction((ReaxTransaction tx) async {
        final Map<String, dynamic> from =
            (await tx.get<Map<String, dynamic>>(_checking))!;
        final Map<String, dynamic> to =
            (await tx.get<Map<String, dynamic>>(_savings))!;
        if ((from['balance'] as int) < amount) {
          throw const InsufficientFunds('checking');
        }
        await tx.put(_checking, <String, dynamic>{
          ...from,
          'balance': (from['balance'] as int) - amount,
        });
        await tx.put(_savings, <String, dynamic>{
          ...to,
          'balance': (to['balance'] as int) + amount,
        });
      }, isolationLevel: IsolationLevel.serializable);
      _console.success('Transferred $amount from checking to savings.');
    } on InsufficientFunds catch (error) {
      _console.warning(
        'Transfer of $amount aborted: $error. Both balances are unchanged — '
        'the transaction never reached its durability point.',
      );
    }
  });

  Future<void> _concurrentTransfers() => _run(() async {
    _console.section('Ten concurrent transfers of 10');
    final int before = _checkingBalance + _savingsBalance;
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < 10; i++)
        widget.db.transaction((ReaxTransaction tx) async {
          final Map<String, dynamic> from =
              (await tx.get<Map<String, dynamic>>(_checking))!;
          final Map<String, dynamic> to =
              (await tx.get<Map<String, dynamic>>(_savings))!;
          await tx.put(_checking, <String, dynamic>{
            ...from,
            'balance': (from['balance'] as int) - 10,
          });
          await tx.put(_savings, <String, dynamic>{
            ...to,
            'balance': (to['balance'] as int) + 10,
          });
        }, isolationLevel: IsolationLevel.serializable),
    ]);
    await _refresh();
    final int after = _checkingBalance + _savingsBalance;
    _console.info('Total before: $before, total after: $after.');
    if (before == after) {
      _console.success('No update was lost: every transfer saw a fresh read.');
    } else {
      _console.failure('The total changed, which should not happen.');
    }
  });

  Future<void> _compareAndSwap() => _run(() async {
    final int current = _counterValue;
    final bool first = await widget.db.compareAndSwap<int>(
      _counter,
      current,
      current + 1,
    );
    final bool second = await widget.db.compareAndSwap<int>(
      _counter,
      current,
      current + 100,
    );
    _console.section('compareAndSwap on counter (was $current)');
    _console.success(
      'Expecting $current: $first, counter is now ${current + 1}.',
    );
    _console.info(
      'Expecting $current again: $second — the value moved on, so the swap '
      'was refused. The read and the write run in one serializable '
      'transaction.',
    );
  });

  @override
  Widget build(BuildContext context) {
    final TransactionStats stats = widget.db.transactionStats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        StatsCard(
          title: 'Balances',
          stats: <Stat>[
            Stat('Checking', '$_checkingBalance'),
            Stat('Savings', '$_savingsBalance'),
            Stat('Total', '${_checkingBalance + _savingsBalance}'),
            Stat('Counter', '$_counterValue'),
          ],
        ),
        const SizedBox(height: 8),
        StatsCard(
          title: 'Transaction statistics',
          stats: <Stat>[
            Stat('Committed', '${stats.committedTransactions}'),
            Stat('Aborted', '${stats.abortedTransactions}'),
            Stat('Active', '${stats.activeTransactions}'),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ActionButton(
              label: 'Transfer 50',
              icon: Icons.arrow_forward,
              onPressed: _busy ? null : () => _transfer(50),
            ),
            ActionButton(
              label: 'Transfer 10000',
              icon: Icons.block,
              tonal: true,
              onPressed: _busy ? null : () => _transfer(10000),
            ),
            ActionButton(
              label: 'Ten at once',
              icon: Icons.dynamic_feed,
              tonal: true,
              onPressed: _busy ? null : _concurrentTransfers,
            ),
            ActionButton(
              label: 'compareAndSwap',
              icon: Icons.swap_calls,
              tonal: true,
              onPressed: _busy ? null : _compareAndSwap,
            ),
            ActionButton(
              label: 'Reset',
              icon: Icons.restart_alt,
              tonal: true,
              onPressed: _busy ? null : _reset,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ConsoleWidget(controller: _console, height: 260),
      ],
    );
  }
}
