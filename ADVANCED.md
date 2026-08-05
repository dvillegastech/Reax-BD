# ReaxDB — advanced guide

Everything here describes behaviour that exists in the code. Where a guarantee
has limits, the limits are stated.

## Contents

- [Opening a database](#opening-a-database)
- [Isolation levels](#isolation-levels)
- [The write pipeline](#the-write-pipeline)
- [Key space and the reserved 0x00 prefix](#key-space-and-the-reserved-0x00-prefix)
- [Storage engine](#storage-engine)
- [Cache](#cache)
- [Queries, indexes and the total order](#queries-indexes-and-the-total-order)
- [Encryption](#encryption)
- [Logging and redaction](#logging-and-redaction)
- [Concurrency model](#concurrency-model)
- [Operational notes](#operational-notes)

## Opening a database

```dart
final db = await ReaxDB.open(
  path: 'data/app',

  // Durability.
  syncMode: SyncMode.full,

  // Encryption.
  encryption: EncryptionConfig.aes256(key: keyBytes32),

  // Storage tuning.
  memtableSizeBytes: 4 * 1024 * 1024,

  // Cache tuning.
  cacheMaxEntries: 10000,
  cacheMaxMemoryBytes: 64 * 1024 * 1024,
  cacheDefaultTtl: null,

  // Logging.
  logLevel: LogLevel.warning,
  logOutputs: [ConsoleLogOutput()],
  loggerName: 'app',

  // Transactions.
  defaultIsolationLevel: IsolationLevel.readCommitted,
  lockTimeout: const Duration(seconds: 10),

  // Schema.
  schemaVersion: 1,
  onUpgrade: null,
);
```

`close()` drains work already accepted, then closes the transaction manager,
the index manager, the storage engine (which flushes the memtable and closes
the WAL), the cache, the change-stream hub and the logger, releases the
on-disk lock and unregisters the instance. It is idempotent.

`ReaxDB.closeAll()` closes every instance open in the current isolate. It
exists for tests and for shutdown hooks.

## Isolation levels

Four levels are implemented. Do not assume more than is listed.

### `IsolationLevel.readCommitted` (default)

Reads take no locks and always observe the latest committed value. Writes take
exclusive key locks held until commit or abort. Dirty reads are impossible
because uncommitted writes never reach storage. Non-repeatable reads are
possible.

### `IsolationLevel.repeatableRead`

Reads take shared key locks held until commit or abort and are served from the
transaction's read set on repeat, so a value read twice never changes. Reading
an absent key also locks that key, which blocks a concurrent insert of that
exact key.

### `IsolationLevel.serializable`

`repeatableRead` plus commit-time revalidation of the whole read set, including
keys read as absent. "Read a missing key, someone else inserts it, commit" is
rejected with `TransactionConflictException`.

**Limit:** point reads and writes are serializable. Range and predicate
phantoms are out of scope, because the transaction API has no range read — a
query executed outside the transaction is not part of its read set.

### `IsolationLevel.optimistic`

No locks. Reads record the committed version of each key; commit revalidates
the version of every key read or written and fails with
`TransactionConflictException` if any changed. First committer wins.

### Retries

`db.transaction(..., maxAttempts: 3)` retries only on
`TransactionConflictException` and `DeadlockException`, with exponential
backoff (`5ms * 2^(attempt-1)`, no jitter). Any other exception aborts and
propagates immediately.

Deadlocks are detected by cycle detection in the lock manager and reported as
`DeadlockException`. `lockTimeout` is a backstop for waits that are not part of
a detected cycle; exceeding it raises `TransactionTimeoutException`.

## The write pipeline

One private method, `ReaxDB._applyMutations`, is the only code path that
mutates storage on behalf of a user write. It runs, in order:

1. **Build the batch.** For each mutation, if the key parses as
   `collection:id` and that collection has indexes, the old document is loaded
   and `IndexManager.buildIndexOps` produces the posting deletes and inserts.
   The value operation is appended to the same list.
2. **`StorageEngine.writeBatch(ops)` — the durability point.** The WAL append
   inside it returns only when the batch is durable per the sync mode. The
   batch is atomic: after a crash either all of it or none of it is visible,
   so a document is never visible without its index postings.
3. **Optional escalation.** A `sync:` override stronger than the database
   default pushes the WAL to the OS or fsyncs it here.
4. **Cache.** Only now. The cache stores the plaintext record envelope — never
   ciphertext, and never before durability, so a failed write cannot leave a
   phantom entry.
5. **Events.** `ChangeStreamHub.publish` for every mutation.

### Transactions and index maintenance

The transaction manager owns the atomic batch for a transaction's values.
After `commit` returns a `CommitResult`, the database walks its
`AppliedOperation` list and performs index maintenance, cache invalidation and
event publication.

**Limit:** index postings for transactional writes are written in a second
batch that follows the commit. If the process dies between the two, the
documents are durable but their index postings for that transaction are not.
Rebuild with `dropIndex` + `createIndex` if you need to recover from that. For
writes where index durability must be atomic with the document, use `put` /
`putBatch`, which put both in one batch.

## Key space and the reserved 0x00 prefix

| Prefix | Contents |
| --- | --- |
| `0x00 'i' 'd' 'x' 0x00 ...` | secondary index postings |
| `0x00 'i' 'd' 'x' 'm' 0x00 ...` | index metadata |
| anything else | user keys |

`ReaxDB.encodeKey` rejects an empty key and any key whose first UTF-8 byte is
`0x00` with `InvalidKeyException`. All iteration APIs start at byte `0x01`, so
internal keys are structurally invisible to `scan`, `scanPrefix`, `keys`,
`range`, `exportTo` and `info().entryCount`.

Index postings are keyed by `(index, encoded field values, document id)` with
an empty value, so inserting or removing one posting is a single key write —
never a read-modify-write of a posting list blob.

## Storage engine

- Leveled LSM tree. Writes go to the WAL and then an in-memory memtable; a
  full memtable is flushed inline to an L0 SSTable and the WAL is checkpointed.
- Each SSTable carries a bloom filter and min/max key fences, so a point read
  skips files that cannot contain the key.
- `scan` merges the memtable snapshot with every SSTable level, honouring
  tombstones with newest-wins. It is the single source of truth for iteration.
- `StorageStats.immutableMemtableCount` is always 0: flushes are inline, so
  there is never a sealed-but-unflushed memtable.
- `flush()` persists the memtable and checkpoints the WAL. `compact()` flushes
  and then compacts every level until size targets are met.

Both `flush()` and `compact()` are serialized against the export snapshot and
the write pipeline, so a snapshot scan can never race a compaction that
deletes the files it is reading.

## Cache

One LRU cache with per-entry TTL, bounded by entry count and by memory.

- It stores exactly one representation: the **plaintext record envelope**,
  after decryption and before deserialization. This makes the 1.x
  double-decrypt bug (put cached ciphertext, get cached plaintext)
  structurally impossible.
- A `get` that finds an expired entry removes it and counts one miss and one
  expiration. One logical lookup is one hit or one miss, never three.
- Prefix invalidation is `O(log n + k)` through a key-sorted view.

`db.cacheStats` reports hits, misses, evictions, expirations, entry count,
memory and hit ratio.

## Queries, indexes and the total order

All value comparisons — conditions, `orderBy`, aggregation, `distinct`,
joins — use one total order:

```text
null < false < true < numbers < strings < lists < maps < other
```

`int` and `double` share one numeric space, so `whereEquals('n', 5)` matches
`5.0`. Strings order by UTF-8 bytes, lists compare element-wise, maps compare
by sorted key/value pairs, and anything else compares by `toString()`. The
comparator is defined as `memcmp` of the index encodings, so the indexed path
and the scan path cannot disagree.

**Limit:** integers with magnitude above 2^53 lose precision inside the
unified numeric space. Because query results are always re-filtered against
the loaded documents, this can only widen an index range scan, never produce a
wrong result.

`IndexManager.candidateIds` returns `null` when no index can serve any
condition (the caller scans) and an empty set when an index was consulted and
nothing matched. Those two cases are never conflated.

Compound indexes are used for an equality prefix plus one trailing range or
`whereIn` component, in field order.

## Encryption

See the envelope layout in the README. Additional details:

- The GCM authentication tag is 128 bits and the IV is a fresh 96-bit value
  from `Random.secure()` per value.
- Decryption validates the envelope version and that the stored algorithm id
  matches the configured algorithm before attempting anything.
- Authentication failure (tampering or a wrong key) throws
  `EncryptionException`. There is no path that returns partially decrypted
  bytes.
- `KeyDerivation.defaultIterations` is 210,000 (the 2023+ OWASP figure for
  PBKDF2-HMAC-SHA256) and `minIterations` is 1,000. Lower values are rejected.
  Tests may pass a low count explicitly; production code should not.
- The salt is per database, generated with `Random.secure()` on first open and
  stored in `reaxdb.meta` together with the iteration count.
- Only values are encrypted. Keys, index postings and the header are
  plaintext.

`db.encryptionInfo` reports the **effective** algorithm, never a requested one.

## Logging and redaction

Loggers are per instance:

```dart
final db = await ReaxDB.open(
  path: 'data/app',
  logLevel: LogLevel.debug,
  logOutputs: [ConsoleLogOutput(), MemoryLogOutput()],
);
```

`ReaxLogger.root` (also exported as the top-level `logger`) remains available
for code not tied to a database. `db.close()` closes the database's logger and
the outputs it owns.

File logging lives behind a separate entry point so the main barrel stays free
of it:

```dart
import 'package:reaxdb_dart/reaxdb_dart_io.dart';

final db = await ReaxDB.open(
  path: 'data/app',
  logOutputs: [FileLogOutput('logs/reaxdb.log')],
);
```

### No-PII policy

ReaxDB never logs key contents, value contents, encryption keys, passphrases
or derived key material, at any level including debug. When a message must
reference a key or value, use the redaction helpers:

```dart
Redaction.key('user:ada@example.com');  // key#3f2a9c1d(len=21)
Redaction.value({'a': 1});              // <redacted Map, 1 entries>
```

`ReaxEntry.toString()` and `DatabaseChangeEvent.toString()` are redacted the
same way, because those objects routinely end up in log lines and exception
messages.

## Concurrency model

ReaxDB is single-isolate. Within an isolate:

- The storage engine serializes every mutation, flush, compaction and close.
- The transaction manager serializes commits behind one mutex.
- The lock manager provides shared/exclusive key locks with upgrade support
  and cycle-based deadlock detection.
- The database facade serializes pipeline writes against export, flush,
  compaction and close.

Concurrent `await`ed calls from the same isolate are safe. Two isolates or two
processes must not open the same directory; the advisory lock enforces that.

## Operational notes

### Choosing a sync mode

- `SyncMode.full` — financial records, anything where losing the last
  acknowledged write is unacceptable. Default.
- `SyncMode.os` — caches and derived data that must survive a crash of your
  process but can be rebuilt after a power cut.
- `SyncMode.none` — throwaway data and benchmarks only.

Prefer batching over lowering the sync mode: `putBatch` costs one durability
barrier for the whole batch.

### Reclaiming space

Deleted and expired entries occupy space until compaction rewrites the level
that holds them. Call `db.compact()` during idle time after a large deletion,
and `db.purgeExpired()` if you rely heavily on TTL.

### Sizing the memtable

A larger `memtableSizeBytes` means fewer flushes and fewer L0 tables, at the
cost of a longer WAL replay on open and more resident memory. The 4 MB default
is a reasonable starting point for mobile.

### Backups

`exportTo` blocks writes for the duration of the scan. On a large database
schedule it when the application is idle. The archive is a single file with a
verified SHA-256 digest; keep the digest failure path in mind when restoring
from cold storage.
