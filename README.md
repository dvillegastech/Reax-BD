# ReaxDB

An embedded NoSQL database for Dart, written in pure Dart with no native
dependencies.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/dvillegastech/Reax-BD)

> **2.0.0 is a rewrite.** The storage engine, transaction manager, query
> layer, encryption and public API all changed. Data written by 1.x cannot be
> read by 2.0 — see [MIGRATION.md](MIGRATION.md).

## What it is

- A log-structured merge-tree key/value store with a write-ahead log.
- Documents (`Map<String, dynamic>`) with secondary and compound indexes,
  a fluent query builder and aggregation.
- ACID transactions with four isolation levels.
- AES-256-GCM encryption of stored values.
- Change streams, TTL, backup/restore, schema migrations.

## What it is not

- **Not a web database.** The engine writes files through `dart:io`. It runs
  on the Dart VM and on Flutter for Android, iOS, macOS, Windows and Linux.
  It does not run on Flutter Web.
- **Not a client/server database.** One process opens a database directory at
  a time, enforced by an OS advisory lock.
- **Not the fastest database in every benchmark.** See
  [BENCHMARKS.md](BENCHMARKS.md) for measured numbers from a reproducible
  harness, with the machine and methodology stated. We do not publish
  comparisons against numbers other people measured on other devices.

## Install

```yaml
dependencies:
  reaxdb_dart: ^2.0.0
```

## Quick start

```dart
import 'package:reaxdb_dart/reaxdb_dart.dart';

Future<void> main() async {
  final db = await ReaxDB.open(path: 'data/myapp');

  await db.put('user:1', {'name': 'Ada', 'age': 36});
  final user = await db.get<Map<String, dynamic>>('user:1');

  await db.close();
}
```

Or the small API, which covers plain key/value use:

```dart
final db = await ReaxDB.simple('myapp');
await db.put('user:1', {'name': 'Ada'});
final user = await db.get('user:1');
await db.close();
```

## Core concepts

### Keys and values

Keys are strings, encoded as UTF-8. They must be non-empty and must not start
with byte `0x00`, which is reserved for ReaxDB's internal key space
(secondary index postings and index metadata). A reserved key throws
`InvalidKeyException`.

Values may be `String`, `int`, `double`, `bool`, `null`, a byte list
(`List<int>`), or anything `jsonEncode` accepts (maps and lists of the above).
Anything else throws `SerializationException` at write time — ReaxDB never
silently stores a mangled value or returns `null` to mean "decode failed".

Documents use the key shape `collection:id`. That is what queries, indexes and
typed collections address.

### Durability contract

An awaited write that returns normally is recoverable, to the extent the
effective sync mode promises:

| `SyncMode` | Behaviour | Survives |
| --- | --- | --- |
| `none` | WAL records buffered in memory, written opportunistically | nothing guaranteed |
| `os` | WAL records handed to the OS with `write()` before the call returns | process kill |
| `full` (default) | WAL records fsynced with `RandomAccessFile.flush()` before the call returns | power loss |

```dart
final db = await ReaxDB.open(path: 'data/app', syncMode: SyncMode.os);

// One individual write that must survive power loss:
await db.put('payment:1', receipt, sync: SyncMode.full);
```

A per-write `sync` override only ever strengthens durability; it cannot weaken
the database default.

### The single write pipeline

Every mutation — `put`, `putBatch`, `delete`, `deleteBatch`, typed collection
writes, query-driven `update`/`delete`, and TTL reclamation — flows through
one internal method that applies, in order:

1. build the batch (value operation + secondary index operations),
2. `writeBatch` — **the durability point**,
3. optional per-write durability escalation,
4. cache update or invalidation,
5. change-event publication.

Nothing observable happens before step 2. The cache is never written before a
write is durable, so a failed write cannot leave a phantom cache entry, and
change events never announce a write that is not on disk.

Transactions are the one two-phase case: the transaction manager owns the
atomic batch for the values, and the database runs index maintenance, cache
invalidation and events immediately after the commit returns. Index updates
for transactional writes are therefore durable in a second batch that follows
the commit.

## Features

### Iteration

```dart
await for (final entry in db.scan<Map<String, dynamic>>(startKey: 'user:', limit: 100)) {
  print('${entry.key} -> ${entry.value}');
}

await for (final entry in db.scanPrefix<String>('session:')) { /* ... */ }
await for (final key in db.keys(prefix: 'user:')) { /* ... */ }
final page = await db.range<int>('a', 'm', limit: 50, reverse: true);
```

Iteration is backed by the storage engine's ordered, tombstone-aware merge
scan. Expired entries are skipped and internal keys are never yielded.

### TTL and expiry

```dart
await db.put('session:abc', token, ttl: const Duration(minutes: 30));
await db.put('promo', banner, expiresAt: DateTime(2026, 1, 1));
```

An expired entry reads as absent (`get` returns null, `exists` returns false,
iteration skips it) and is reclaimed lazily when it is next read. Call
`db.purgeExpired()` to reclaim everything eagerly. The in-memory cache honours
the same expiry instant.

### Typed collections, without code generation

```dart
class User {
  User({required this.id, required this.name});
  factory User.fromJson(Map<String, dynamic> j) =>
      User(id: j['id'] as String, name: j['name'] as String);
  final String id;
  final String name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

final users = db.collection<User>(
  'users',
  fromJson: User.fromJson,
  toJson: (u) => u.toJson(),
);

await users.put('1', User(id: '1', name: 'Ada'));
final ada = await users.get('1');
final adults = await users.where('age', QueryOperator.greaterThan, 18);
users.watch().listen((change) => print(change.value?.name));
```

Typed collections store ordinary documents under `users:<id>`, so they share
indexes, queries and change streams with untyped access.

### Indexes and queries

```dart
await db.createIndex('users', ['city']);            // single field
await db.createIndex('users', ['city', 'age']);     // compound

final results = await db.query('users')
    .whereEquals('city', 'London')
    .whereGreaterThanOrEqual('age', 18)
    .orderBy('age', descending: true)
    .limit(20)
    .find();
```

Index entries live in the same storage engine as documents under the reserved
`0x00` prefix, so a document write and its index maintenance commit in one
atomic batch. `createIndex` backfills from existing data.

### Transactions

```dart
await db.transaction((tx) async {
  final from = await tx.get<Map<String, dynamic>>('account:1');
  final to = await tx.get<Map<String, dynamic>>('account:2');
  await tx.put('account:1', {...from!, 'balance': from['balance'] - 50});
  await tx.put('account:2', {...to!, 'balance': to['balance'] + 50});
}, isolationLevel: IsolationLevel.serializable);
```

Available isolation levels and what they actually provide are documented in
[ADVANCED.md](ADVANCED.md#isolation-levels).

`compareAndSwap` runs its read and write inside one serializable transaction,
so it is genuinely atomic:

```dart
final swapped = await db.compareAndSwap<int>('counter', 1, 2);
```

### Change streams

```dart
final subscription = db.watch('user:*').listen((event) {
  print('${event.type} ${event.key}');
});
```

`*` matches everything, `prefix*` matches by prefix, anything else is an exact
key. Events fire only after the durability point. `ReaxEntry.toString()` and
`DatabaseChangeEvent.toString()` are redacted: they never print key or value
content.

### Encryption

```dart
// Raw key you already manage (for example from a platform keystore).
final db = await ReaxDB.open(
  path: 'data/secure',
  encryption: EncryptionConfig.aes256(key: keyBytes32),
);

// Or derive one from a passphrase with PBKDF2-HMAC-SHA256.
final db = await ReaxDB.open(
  path: 'data/secure',
  encryption: EncryptionConfig.aes256FromPassphrase(passphrase: secret),
);
```

Values are wrapped in a self-describing envelope:

```text
byte 0      envelope version (0x01)
byte 1      algorithm id (0x01 = XOR obfuscation, 0x02 = AES-256-GCM)
AES-GCM:    bytes 2..13  random 96-bit IV from Random.secure()
            bytes 14..   ciphertext || 16-byte authentication tag
```

For a passphrase configuration the random PBKDF2 salt and the iteration count
are generated on first open and stored in the database header, so later opens
derive the same key. Reopening with a different algorithm, a different
iteration count or the wrong key fails loudly with `EncryptionException` —
ReaxDB never downgrades to a weaker cipher and never silently returns garbage.

`EncryptionConfig.obfuscation` exists and is honestly named: repeating-key XOR
is **not** encryption, provides no confidentiality and no integrity, and must
not be used for sensitive data.

Keys are not encrypted, only values. Key names should not themselves be
secrets.

### Backup and restore

```dart
await db.exportTo('backups/2026-07-30.rxdb');

final restored = await ReaxDB.importFrom(
  archivePath: 'backups/2026-07-30.rxdb',
  path: 'data/restored',
);
```

The archive has a magic number, a format version, a SHA-256 digest verified on
import, the schema version and the index definitions. Its records are stored
decrypted, so a backup from an encrypted database can be restored into a
database with different (or no) encryption. Writes are blocked for the
duration of the snapshot scan, so the archive is a point-in-time image.

### Schema versions and migrations

```dart
final db = await ReaxDB.open(
  path: 'data/app',
  schemaVersion: 2,
  onUpgrade: (from, to, db) async {
    await for (final entry in db.scanPrefix<Map<String, dynamic>>('user:')) {
      await db.put(entry.key, {...entry.value, 'schema': to});
    }
  },
);
```

The version lives in the database header. Opening at a lower version than the
stored one throws `SchemaVersionException` — there are no downgrades. Opening
at a higher version without an `onUpgrade` callback also throws, rather than
reinterpreting old data.

### One writer per database

A second `ReaxDB.open` of the same path in the same isolate throws
`DatabaseLockedException`. Across processes the guard is an OS advisory lock
on `<path>/LOCK`. Because the operating system releases advisory locks when a
process dies, a crash never leaves a stale lock: the file remains on disk but
is unlocked, and the next open succeeds. There is no timeout to tune and no
force-unlock switch.

## Upgrading from 1.x

**Your data comes with you.** 2.0 reads the 1.x on-disk formats — including
1.x ciphertext — and migrates them into a 2.0 database. Opening a 1.x
directory with the default settings throws `SchemaVersionException` with
instructions instead of touching your files; ReaxDB never rewrites data
without being told to.

```dart
// migrate on first open; the 1.x files are kept in data/myapp.1x-backup-<n>
final db = await ReaxDB.open(
  path: 'data/myapp',
  legacyMigration: LegacyMigrationMode.automatic,
  // only for a database that 1.x encrypted:
  legacyEncryptionKey: 'the key 1.x was opened with',
  encryption: EncryptionConfig.aes256FromPassphrase(passphrase: mySecret),
);

// or migrate explicitly and inspect the report
final report = await ReaxDB.migrateFrom1x(
  sourcePath: 'data/myapp',
  targetPath: 'data/myapp-v2',
);
```

Migration re-encrypts with the 2.0 scheme; the 1.x key derivation is used for
reading only. It reproduces what 1.x wrote, but it cannot repair what 1.x had
already lost — dropped tombstones, stale values after compaction, colliding
keys over 32 bytes. Anomalies it can see land in `MigrationReport.warnings`.

**Your code keeps compiling.** The 1.x API is still there, deprecated and
mapped onto the 2.0 one; `dart analyze` points at every call to fix before
3.0. Two shims deliberately throw instead of running:
`ReaxDB.simple(name, encrypted: true)` (the key came from the database name)
and mixing `encryptionKey:` with `encryption:`.

[MIGRATION.md](MIGRATION.md) has the full guide and a table of every renamed,
removed and shimmed API.

## Errors

Every failure is a subtype of the sealed `ReaxDbException`:

`DatabaseClosedException`, `DatabaseLockedException`, `InvalidKeyException`,
`CorruptionException`, `EncryptionException`, `TransactionConflictException`,
`DeadlockException`, `TransactionTimeoutException`, `SchemaVersionException`,
`SerializationException`, `QueryException`, `UnsupportedApiException`.

Nothing is swallowed into a `null` or an empty result.

## Documentation

- [ADVANCED.md](ADVANCED.md) — isolation levels, tuning, logging, internals
- [MIGRATION.md](MIGRATION.md) — moving from 1.x to 2.0
- [BENCHMARKS.md](BENCHMARKS.md) — measured performance and methodology
- [CHANGELOG.md](CHANGELOG.md)

## Contributing

Issues and pull requests are welcome at
<https://github.com/dvillegastech/Reax-BD>. A bug fix should come with a test
that fails before it and passes after.

## License

MIT — see [LICENSE](LICENSE).
