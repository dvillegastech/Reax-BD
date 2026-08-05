/// Key-level lock manager used by the transaction layer.
///
/// Supports shared/exclusive locks with in-place lock upgrades, a fair FIFO
/// wait queue, wait-for graph deadlock detection (youngest transaction is
/// aborted), and a timeout backstop. Lock keys are plain strings kept in a
/// dedicated map slot per key, so keys containing arbitrary characters
/// (including `_` or `:`) can never collide or cross-notify.
library;

import 'dart:async';

import '../errors/exceptions.dart';

/// The mode of a key lock.
enum LockType {
  /// Multiple transactions may hold a shared lock on the same key.
  shared,

  /// Only one transaction may hold an exclusive lock, and no shared locks
  /// from other transactions may coexist with it.
  exclusive,
}

/// A single blocked lock request.
class _Waiter {
  _Waiter(this.key, this.transactionId, this.mode);

  final String key;
  final int transactionId;
  final LockType mode;
  final Completer<void> completer = Completer<void>();
}

/// Per-key lock bookkeeping: current holders and the FIFO wait queue.
class _KeyLockState {
  /// Current holders, transaction id to granted mode.
  final Map<int, LockType> holders = <int, LockType>{};

  /// Blocked requests in arrival order (upgrades are inserted at the front).
  final List<_Waiter> queue = <_Waiter>[];

  bool get isIdle => holders.isEmpty && queue.isEmpty;
}

/// Grants shared and exclusive locks on string keys to transactions.
///
/// Correctness properties:
///
/// * A transaction holding a shared lock that requests an exclusive lock on
///   the same key performs a lock *upgrade*: it is granted immediately when
///   it is the sole holder, and otherwise waits at the front of the queue
///   until the other shared holders release (it never self-deadlocks).
/// * Wake-up is fair: on every release the wait queue is scanned from the
///   front and every request that has become grantable is granted before its
///   future completes, so a woken waiter can never "lose the race" and hang.
/// * Deadlocks between transactions are detected with a wait-for graph the
///   moment a request blocks; the youngest transaction (highest id) in the
///   cycle is aborted with a [DeadlockException].
/// * Every blocked request also carries a timeout backstop
///   ([TransactionTimeoutException]); timed-out and aborted waiters are
///   always removed from the queue, so no queue entries leak.
final class LockManager {
  /// Creates a lock manager whose blocked requests give up after
  /// [defaultTimeout] unless a per-call timeout is given.
  LockManager({this.defaultTimeout = const Duration(seconds: 10)});

  /// Timeout applied to [acquire] calls that do not pass an explicit timeout.
  final Duration defaultTimeout;

  final Map<String, _KeyLockState> _keys = <String, _KeyLockState>{};

  /// Number of keys that currently have holders or waiters (for tests).
  int get lockedKeyCount => _keys.length;

  /// Number of blocked lock requests across all keys (for tests).
  int get waiterCount =>
      _keys.values.fold(0, (int sum, _KeyLockState s) => sum + s.queue.length);

  /// Returns whether [transactionId] holds a lock on [key] that satisfies
  /// [mode] (an exclusive lock satisfies a shared request).
  bool holdsLock(String key, int transactionId, LockType mode) {
    final LockType? held = _keys[key]?.holders[transactionId];
    if (held == null) return false;
    return held == LockType.exclusive || mode == LockType.shared;
  }

  /// Acquires a [mode] lock on [key] for [transactionId], waiting if needed.
  ///
  /// Re-acquiring an already-satisfied lock returns immediately. A shared
  /// holder requesting exclusive performs an upgrade. Throws
  /// [DeadlockException] if this request closes a wait cycle and this
  /// transaction is chosen as the victim (or if it is aborted while waiting
  /// to break a cycle), and [TransactionTimeoutException] if the lock cannot
  /// be granted within the timeout. On any throw the request is fully
  /// removed from the wait queue; locks already held are NOT released here
  /// (the transaction layer releases them via [releaseAll] on abort).
  Future<void> acquire(
    String key,
    int transactionId,
    LockType mode, {
    Duration? timeout,
  }) async {
    final _KeyLockState state = _keys.putIfAbsent(key, _KeyLockState.new);
    final LockType? held = state.holders[transactionId];

    // Already satisfied (exclusive covers shared).
    if (held == LockType.exclusive ||
        (held == LockType.shared && mode == LockType.shared)) {
      return;
    }

    final bool isUpgrade =
        held == LockType.shared && mode == LockType.exclusive;

    // Immediate grant: upgrades may barge (they must, to avoid deadlocking
    // behind waiters that can never run first); fresh requests only when no
    // one is queued ahead of them, to keep FIFO fairness.
    if (_canGrant(state, transactionId, mode) &&
        (isUpgrade || state.queue.isEmpty)) {
      state.holders[transactionId] = mode;
      return;
    }

    final _Waiter waiter = _Waiter(key, transactionId, mode);
    if (isUpgrade) {
      // Upgrades wait at the front, after other pending upgrades.
      final int firstNormal = state.queue.indexWhere(
        (_Waiter w) => state.holders[w.transactionId] != LockType.shared,
      );
      if (firstNormal == -1) {
        state.queue.add(waiter);
      } else {
        state.queue.insert(firstNormal, waiter);
      }
    } else {
      state.queue.add(waiter);
    }

    // This request just blocked: check for a wait cycle.
    try {
      _detectAndResolveDeadlock(transactionId);
    } on DeadlockException {
      _removeWaiter(waiter);
      rethrow;
    }

    try {
      await waiter.completer.future.timeout(timeout ?? defaultTimeout);
    } on TimeoutException catch (e) {
      _removeWaiter(waiter);
      throw TransactionTimeoutException(
        'Transaction $transactionId timed out waiting for a '
        '${mode.name} lock on "$key"',
        transactionId: transactionId,
        cause: e,
      );
    } on DeadlockException {
      // Completed with an error by the deadlock resolver, which already
      // removed the waiter; removing again is a safe no-op.
      _removeWaiter(waiter);
      rethrow;
    }
  }

  /// Releases every lock held by [transactionId] and cancels any of its
  /// still-blocked requests, then wakes all newly grantable waiters.
  void releaseAll(int transactionId) {
    final List<String> affected = <String>[];
    for (final MapEntry<String, _KeyLockState> entry in _keys.entries) {
      final _KeyLockState state = entry.value;
      bool touched = state.holders.remove(transactionId) != null;
      for (final _Waiter w
          in state.queue
              .where((_Waiter w) => w.transactionId == transactionId)
              .toList()) {
        state.queue.remove(w);
        touched = true;
        if (!w.completer.isCompleted) {
          w.completer.completeError(
            TransactionConflictException(
              'Lock request cancelled: transaction $transactionId '
              'released its locks while waiting for "${w.key}"',
              transactionId: transactionId,
            ),
          );
        }
      }
      if (touched) affected.add(entry.key);
    }
    for (final String key in affected) {
      _grantPass(key);
    }
  }

  /// Whether [transactionId] could be granted [mode] right now, considering
  /// only current holders (queue fairness is handled by callers).
  bool _canGrant(_KeyLockState state, int transactionId, LockType mode) {
    for (final MapEntry<int, LockType> holder in state.holders.entries) {
      if (holder.key == transactionId) continue;
      if (mode == LockType.exclusive || holder.value == LockType.exclusive) {
        return false;
      }
    }
    return true;
  }

  /// Grants queued requests for [key] in FIFO order until the head cannot be
  /// granted. Grants are applied to the holder map BEFORE the waiter future
  /// completes, so woken waiters never re-race for the lock.
  void _grantPass(String key) {
    final _KeyLockState? state = _keys[key];
    if (state == null) return;
    while (state.queue.isNotEmpty) {
      final _Waiter w = state.queue.first;
      if (!_canGrant(state, w.transactionId, w.mode)) break;
      state.queue.removeAt(0);
      state.holders[w.transactionId] = w.mode;
      if (!w.completer.isCompleted) w.completer.complete();
    }
    if (state.isIdle) _keys.remove(key);
  }

  /// Removes [waiter] from its key queue if still present (idempotent).
  void _removeWaiter(_Waiter waiter) {
    final _KeyLockState? state = _keys[waiter.key];
    if (state == null) return;
    state.queue.remove(waiter);
    if (state.isIdle) {
      _keys.remove(waiter.key);
    } else {
      // Its departure may unblock waiters behind it.
      _grantPass(waiter.key);
    }
  }

  /// Builds the wait-for graph and, if [newlyBlocked] participates in a
  /// cycle, aborts the youngest transaction in that cycle.
  ///
  /// If the victim is [newlyBlocked] itself this throws [DeadlockException]
  /// directly; otherwise the victim's blocked request is completed with a
  /// [DeadlockException], which makes its `acquire` call throw and its
  /// transaction abort (releasing its locks and breaking the cycle).
  void _detectAndResolveDeadlock(int newlyBlocked) {
    final Map<int, Set<int>> waitsFor = <int, Set<int>>{};
    for (final _KeyLockState state in _keys.values) {
      for (int i = 0; i < state.queue.length; i++) {
        final _Waiter w = state.queue[i];
        final Set<int> edges = waitsFor.putIfAbsent(
          w.transactionId,
          () => <int>{},
        );
        for (final MapEntry<int, LockType> holder in state.holders.entries) {
          if (holder.key == w.transactionId) continue;
          if (w.mode == LockType.exclusive ||
              holder.value == LockType.exclusive) {
            edges.add(holder.key);
          }
        }
        for (int j = 0; j < i; j++) {
          final _Waiter ahead = state.queue[j];
          if (ahead.transactionId == w.transactionId) continue;
          if (w.mode == LockType.exclusive ||
              ahead.mode == LockType.exclusive) {
            edges.add(ahead.transactionId);
          }
        }
      }
    }

    final List<int>? cycle = _findCycle(waitsFor, newlyBlocked);
    if (cycle == null) return;

    final int victim = cycle.reduce((int a, int b) => a > b ? a : b);
    final DeadlockException error = DeadlockException(
      'Deadlock detected among transactions $cycle; '
      'aborting youngest transaction $victim',
      transactionId: victim,
    );
    if (victim == newlyBlocked) throw error;

    for (final _KeyLockState state in _keys.values.toList()) {
      for (final _Waiter w
          in state.queue
              .where((_Waiter w) => w.transactionId == victim)
              .toList()) {
        state.queue.remove(w);
        if (!w.completer.isCompleted) w.completer.completeError(error);
      }
    }
    // The victim's departure from queues may already unblock others.
    for (final String key in _keys.keys.toList()) {
      _grantPass(key);
    }
  }

  /// Depth-first search for a cycle reachable from [start]; returns the
  /// transaction ids forming the cycle, or null.
  List<int>? _findCycle(Map<int, Set<int>> edges, int start) {
    final List<int> path = <int>[];
    final Set<int> onPath = <int>{};
    final Set<int> visited = <int>{};

    List<int>? dfs(int node) {
      if (onPath.contains(node)) {
        return path.sublist(path.indexOf(node));
      }
      if (!visited.add(node)) return null;
      path.add(node);
      onPath.add(node);
      for (final int next in edges[node] ?? const <int>{}) {
        final List<int>? cycle = dfs(next);
        if (cycle != null) return cycle;
      }
      path.removeLast();
      onPath.remove(node);
      return null;
    }

    return dfs(start);
  }
}
