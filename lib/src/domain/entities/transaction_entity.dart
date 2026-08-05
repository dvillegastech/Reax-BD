/// Value types shared by the transaction layer and the database facade.
library;

import 'dart:typed_data';

/// Concurrency-control mode of a transaction.
///
/// The pessimistic levels use key locks; [optimistic] uses version
/// validation at commit time instead of locks.
enum IsolationLevel {
  /// Reads always see the latest committed value and take no read locks.
  /// Writes take exclusive locks held until commit/abort. Non-repeatable
  /// reads are possible; dirty reads are not (uncommitted writes never
  /// reach storage).
  readCommitted,

  /// Reads take shared locks held until commit/abort and are served from
  /// the transaction's read set on repeat, so a value read twice never
  /// changes. Reads of absent keys also lock the key, blocking concurrent
  /// inserts of that exact key.
  repeatableRead,

  /// [repeatableRead] plus commit-time validation of the full read set,
  /// including keys that were read as absent (so "read missing key,
  /// concurrent insert, commit" is rejected). Point reads and writes are
  /// serializable; range/predicate phantoms are out of scope because the
  /// transaction API has no range reads.
  serializable,

  /// No locks at all. Reads record the committed version of each key;
  /// commit atomically re-validates every read and written key's version
  /// and fails with a conflict if any changed since. First committer wins.
  optimistic,
}

/// Lifecycle state of a transaction.
enum TransactionState {
  /// Accepting operations.
  active,

  /// Commit in progress (validation or batch write running).
  preparing,

  /// Successfully committed; its write set is durable.
  committed,

  /// Rolled back; none of its writes were applied.
  aborted,
}

/// The kind of mutation a committed transaction applied to a key.
enum AppliedOperationType {
  /// The key was inserted or overwritten.
  put,

  /// The key was removed.
  delete,
}

/// One key mutation applied by a committed transaction.
///
/// [key] is the exact key string that was passed to `Transaction.put` /
/// `Transaction.delete` (the facade composes and parses any
/// collection-prefixed key format itself). [oldValue] is the committed
/// value that existed immediately before the transaction's batch was
/// applied (null if the key was absent), and [newValue] is the value
/// written (null for a delete).
class AppliedOperation {
  /// Creates a record of a single applied mutation.
  const AppliedOperation({
    required this.type,
    required this.key,
    required this.oldValue,
    required this.newValue,
  });

  /// Whether the key was written or deleted.
  final AppliedOperationType type;

  /// The key exactly as used inside the transaction.
  final String key;

  /// Committed value before the transaction, or null if absent.
  final Uint8List? oldValue;

  /// Value written by the transaction, or null for a delete.
  final Uint8List? newValue;

  @override
  String toString() => 'AppliedOperation(${type.name} $key)';
}

/// The result of a successful transaction commit.
///
/// The facade consumes [operations] to invalidate caches, update secondary
/// indexes, and emit change events for exactly the keys the transaction
/// changed. Operations are listed in the order they were applied (last
/// write per key; a transaction's write set holds one operation per key).
class CommitResult {
  /// Creates a commit result.
  const CommitResult({required this.transactionId, required this.operations});

  /// Identifier of the committed transaction.
  final int transactionId;

  /// Every mutation the commit applied, one entry per distinct key.
  final List<AppliedOperation> operations;

  @override
  String toString() =>
      'CommitResult(tx: $transactionId, operations: ${operations.length})';
}

/// Counters describing the transaction manager's activity.
class TransactionStats {
  /// Creates a stats snapshot.
  const TransactionStats({
    required this.activeTransactions,
    required this.committedTransactions,
    required this.abortedTransactions,
  });

  /// Transactions currently active or preparing.
  final int activeTransactions;

  /// Total transactions committed since the manager was created.
  final int committedTransactions;

  /// Total transactions aborted since the manager was created.
  final int abortedTransactions;

  @override
  String toString() =>
      'TransactionStats(active: $activeTransactions, '
      'committed: $committedTransactions, aborted: $abortedTransactions)';
}
