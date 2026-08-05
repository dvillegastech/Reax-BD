/// A deliberately small API over [ReaxDB] for straightforward key/value use.
library;

import 'dart:async';

import 'core/encryption/encryption_config.dart';
import 'core/errors/exceptions.dart';
import 'core/wal/write_ahead_log.dart' show SyncMode;
import 'domain/entities/database_entity.dart';
import 'reaxdb.dart';

/// A small key/value API covering the common case.
///
/// ```dart
/// final db = await ReaxDB.simple('myapp');
/// await db.put('user:1', {'name': 'Ada'});
/// final user = await db.get('user:1');
/// await db.close();
/// ```
///
/// Two 1.x behaviours are gone on purpose:
///
/// - **No key derived from the database name.** ReaxDB 1.x built an
///   "encryption key" out of the database name, which meant every database
///   with the same name shared a guessable key. Encryption here is opt-in and
///   always takes real key material through an [EncryptionConfig].
/// - **No key registry.** 1.x kept the full key set in one value that was
///   rewritten on every put, making writes O(total keys) and losing keys on
///   a crash. Iteration now uses the storage engine's ordered scan.
///
/// Anything not covered here is available on [advanced].
final class SimpleReaxDB {
  SimpleReaxDB._(this._db);

  final ReaxDB _db;

  /// Opens a simple database named [name].
  ///
  /// The database directory is `path ?? name`. Pass an [encryption]
  /// configuration to encrypt values; the default stores plaintext.
  ///
  /// The deprecated 1.x [encrypted] flag is accepted so old code compiles,
  /// but `encrypted: true` throws [EncryptionException]: it used to derive
  /// the key from [name], which made every database with that name share a
  /// guessable key. That behaviour is not coming back.
  static Future<SimpleReaxDB> open(
    String name, {
    String? path,
    EncryptionConfig encryption = const EncryptionConfig.none(),
    SyncMode syncMode = SyncMode.full,
    @Deprecated(
      'Pass encryption: EncryptionConfig.aes256FromPassphrase(passphrase: ...) '
      'instead; the 1.x flag derived the key from the database name. '
      'Removed in 3.0.',
    )
    bool encrypted = false,
  }) async {
    if (encrypted) {
      throw EncryptionException(
        'SimpleReaxDB.open(name, encrypted: true) is not supported: ReaxDB '
        '1.x derived the key from the database name "$name", so every '
        'database called "$name" shared the same guessable key. Pass real key '
        'material instead:\n'
        '  ReaxDB.simple("$name", encryption: '
        'EncryptionConfig.aes256FromPassphrase(passphrase: mySecret));\n'
        'Data written by 1.x with encrypted: true was never meaningfully '
        'protected; treat it as plaintext and re-key it after migrating.',
      );
    }
    final ReaxDB db = await ReaxDB.open(
      path: path ?? name,
      encryption: encryption,
      syncMode: syncMode,
      loggerName: name,
    );
    return SimpleReaxDB._(db);
  }

  /// Stores [value] under [key]. Values may be any primitive, byte list, or
  /// JSON-encodable structure.
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      _db.put(key, value, ttl: ttl);

  /// Stores every pair of [entries] atomically.
  Future<void> putAll(Map<String, Object?> entries, {Duration? ttl}) =>
      _db.putBatch(entries, ttl: ttl);

  /// Reads [key], or null when absent or expired.
  Future<Object?> get(String key) => _db.get<Object?>(key);

  /// Removes [key].
  Future<void> delete(String key) => _db.delete(key);

  /// Removes every key in [keys] atomically.
  Future<void> deleteAll(List<String> keys) => _db.deleteBatch(keys);

  /// Whether [key] holds a live value.
  Future<bool> exists(String key) => _db.exists(key);

  /// Returns the keys matching [pattern].
  ///
  /// `*` matches everything and `prefix*` matches by prefix; both are served
  /// by an ordered range scan. Any other pattern is applied as a glob over a
  /// full key scan.
  Future<List<String>> query(String pattern) async {
    if (pattern == '*') return _db.keys().toList();
    if (pattern.indexOf('*') == pattern.length - 1 && pattern.length > 1) {
      return _db
          .keys(prefix: pattern.substring(0, pattern.length - 1))
          .toList();
    }
    if (!pattern.contains('*') && !pattern.contains('?')) {
      return await _db.exists(pattern) ? <String>[pattern] : <String>[];
    }
    final RegExp regex = RegExp(
      '^${pattern.split(RegExp(r'[*?]')).map(RegExp.escape).join('.*')}\$',
    );
    return <String>[
      await for (final String key in _db.keys())
        if (regex.hasMatch(key)) key,
    ];
  }

  /// Returns the key/value pairs whose keys match [pattern].
  Future<Map<String, Object?>> getAll(String pattern) async {
    final Map<String, Object?> results = <String, Object?>{};
    for (final String key in await query(pattern)) {
      results[key] = await get(key);
    }
    return results;
  }

  /// Counts the keys matching [pattern].
  Future<int> count([String pattern = '*']) async =>
      (await query(pattern)).length;

  /// Removes every entry in the database.
  Future<void> clear() async {
    final List<String> all = await _db.keys().toList();
    await _db.deleteBatch(all);
  }

  /// Streams change events matching [pattern] (default: everything).
  Stream<DatabaseChangeEvent> watch([String pattern = '*']) =>
      _db.watch(pattern);

  /// A description of the underlying database.
  Future<DatabaseInfo> info() => _db.info();

  /// The full [ReaxDB] API: transactions, typed collections, indexes,
  /// queries, backups and tuning.
  ReaxDB get advanced => _db;

  /// Closes the database.
  Future<void> close() => _db.close();
}
