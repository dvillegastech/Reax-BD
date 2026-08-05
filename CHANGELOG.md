# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-07-30

A rewrite of the storage engine, transaction manager, query layer, encryption
and public API. Correctness and durability were the goal; several 1.x features
were deleted rather than patched because they could not be made correct.

**1.x data migrates.** This corrects an earlier statement in this changelog
that 1.x data could not be read by 2.0. It can: 2.0 ships read-only readers
for the 1.x SSTable, WAL and encryption formats and migrates their contents
into a 2.0 database. **Encrypted 1.x data is recoverable too** — pass the
original key as `legacyEncryptionKey` — which corrects the earlier claim that
1.x ciphertext was unreadable. Migration never deletes the 1.x files and never
writes the 1.x format. See [MIGRATION.md](MIGRATION.md).

Most 1.x code also still compiles: the old API survives as deprecated shims,
removed in 3.0.

### Added — migrating from 1.x

- `ReaxDB.open(..., legacyMigration: LegacyMigrationMode.detect | automatic |
  off)`. The default, `detect`, throws `SchemaVersionException` explaining
  exactly how to migrate rather than rewriting a user's data; `automatic`
  migrates in place keeping the backup and logs the `MigrationReport`; `off`
  ignores the 1.x files.
- `ReaxDB.migrateFrom1x(...)` and `ReaxDB.inspect1x(path)`, plus the public
  `LegacyMigration`, `LegacyDatabaseInfo` and `MigrationReport` types.
- `legacyEncryptionKey:` on `open` and `migrateFrom1x` for encrypted 1.x
  sources. The 1.x derivation reads only; migrated data is re-encrypted with
  PBKDF2 + a random per-database salt and AES-256-GCM.
- Migration reports what it cannot vouch for: skipped records, duplicate keys
  across levels and other anomalies land in `MigrationReport.warnings`. It
  recovers what 1.x wrote; it cannot repair what 1.x had already lost
  (dropped tombstones, stale values after compaction, the 256-bucket hash
  collision for keys over 32 bytes).

### Breaking changes

Everything below marked "deprecated shim" still compiles in 2.0 and is removed
in 3.0.

- `ReaxDB.open` takes named parameters with a required `path`. Deprecated
  shim: `ReaxDB.openLegacy('name', config:, encryptionKey:, path:)` keeps the
  1.x call shape — Dart does not allow a method to take both an optional
  positional parameter and named ones, so it could not stay on `open`.
  `config:` and `encryptionKey:` are also accepted by `open` itself.
- `DatabaseConfig` deprecated. Real knobs map to `ReaxDB.open`; knobs that did
  nothing (`pageSize`, `compressionEnabled`, `cacheSize`, `enableCache`,
  `maxImmutableMemtables`) are accepted and ignored.
- `encryptionKey: String` deprecated but honoured, with a deliberate
  difference: the key is now derived with PBKDF2-HMAC-SHA256 and a random salt
  stored in the header, not the 1.x 10,001-round SHA-256 with a hardcoded
  package-wide salt. Databases created this way are new databases, not 1.x
  ones; 1.x data must be migrated. A key with no explicit type now means
  AES-256 (1.x stored plaintext in that case).
- `ReaxDB.simple(name, encrypted: true)` throws `EncryptionException` naming
  the replacement. It derived the encryption key from the database name; that
  is not coming back. `encrypted: false` is a no-op.
- `ReaxDB.quickStart` deprecated, delegates to `ReaxDB.simple`.
- `EnhancedTransaction`, `EnhancedTransactionManager`,
  `beginEnhancedTransaction`, `beginReadOnlyTransaction`, `withTransaction`
  and `TransactionType` removed with no shim — that manager never wrote to
  storage, so no shim could be faithful.
- `EncryptionType.xor` renamed to `EncryptionType.obfuscation`; the old name
  survives as a deprecated constant with the same value, so it cannot be used
  as a `switch` pattern. The XOR "AES fallback" is deleted.
- New `UnsupportedApiException` for 1.x calls 2.0 cannot honour safely.
- `DatabaseException` removed with no shim: an alias or superclass would have
  broken the sealed `ReaxDbException` hierarchy that makes exhaustive
  `switch`es over ReaxDB failures possible. Every failure is now a subtype of
  `ReaxDbException`.
- `db.collection(name)` now returns a typed `ReaxCollection<T>`;
  `db.query(name)` returns the `QueryBuilder`.
- `createIndex`/`dropIndex` take a `List<String>` of fields; `listIndexes`
  returns `List<IndexDefinition>`.
- `db.changeStream`, `db.stream`, `db.watchPattern` replaced by
  `db.watch(pattern)`, `db.watchKey`, `db.watchPrefix`, `db.watchCollection`
  and `db.changes`.
- `ChangeType.update` removed; writes are `put`, removals are `delete`.
- `getDatabaseInfo()`, `getStatistics()`, `getPerformanceStats()`,
  `getEncryptionInfo()`, `changeStream`, `stream(pattern)` and
  `watchPattern(pattern)` replaced by `info()`, `statistics()`,
  `encryptionInfo`, `cacheStats`, `storageStats`, `transactionStats` and
  `watch(pattern)`; all seven survive as deprecated shims returning real
  measured data. `getPerformanceStats()` no longer reports the
  `optimization` block of hardcoded `true` values, and `getDatabaseInfo()`
  returns the real path instead of the literal `'database_path'`.
- The barrel no longer exports `HybridStorageEngine`, `MultiLevelCache`,
  `EncryptionEngine`, `IndexManager` or the raw transaction manager. Exporting
  them froze internals as public API.
- Keys are encoded with UTF-8 instead of `String.codeUnits`, and keys starting
  with byte `0x00` are rejected (reserved for the internal index key space).
- `DatabaseEntry`, `StorageConfig` and the old `CacheStats` value types are
  removed; `ReaxEntry<T>`, `DatabaseInfo` and `CacheStatistics` replace them.

### Fixed — durability

- Writes are acknowledged only after the write-ahead log record is durable per
  the effective sync mode. `RandomAccessFile.flush()` (a real fsync) is used
  for `SyncMode.full`; `IOSink.flush()` is not treated as an fsync.
- Batch writes are atomic: a crash mid-batch leaves all or none of it visible.
- WAL replay discards writes of transactions with no commit record, truncates
  a torn tail, and throws `CorruptionException` on a mid-file checksum
  failure. Replay is idempotent.
- Documents and their secondary index postings commit in one batch, so a
  document can never be durable while invisible to indexed queries.

### Fixed — correctness

- The cache stores exactly one representation (the plaintext record envelope).
  1.x cached ciphertext on write and plaintext on read, so reading back a
  freshly written encrypted value double-decrypted it.
- The cache is written after the durability point, not before, so a failed
  write cannot leave a phantom cache entry.
- Change events are published only after the durability point.
- `compareAndSwap` runs its comparison and write inside one serializable
  transaction; it was two unsynchronised operations.
- `scan` and `scanPrefix` were stubs that always returned an empty map. They
  are implemented over the engine's ordered, tombstone-aware merge scan.
- Query `update`/`delete` address documents by the key they were loaded from,
  not by an id reconstructed from document fields.
- `IndexManager.candidateIds` distinguishes "no index can serve this" (null)
  from "an index was consulted and nothing matched" (empty set).
- Indexed and scanned query execution share one documented total value order,
  so they cannot disagree; `5` and `5.0` compare equal.
- `ReactiveStream` operators keep their state per subscription instead of
  sharing timers and counters between listeners.
- The simple API no longer keeps a key registry rewritten on every `put`
  (O(total keys) per write, and keys lost if the registry write was
  interrupted). Iteration uses the storage engine.
- `getDatabaseInfo()` reported a fabricated path and timestamps.
- Cache statistics counted one logical miss three times.

### Fixed — security

- No key is ever derived from the database name.
- PBKDF2-HMAC-SHA256 from `package:pointycastle` with a per-database random
  salt (`Random.secure()`), persisted in the database header with its
  iteration count. Default 210,000 iterations, minimum 1,000.
- AES-256-GCM with a fresh random 96-bit IV per value and a 128-bit
  authentication tag. Tampering and wrong keys are detected and raise
  `EncryptionException`.
- Ciphertext carries a versioned, self-describing envelope; the stored
  algorithm is validated against the configured one.
- ReaxDB never downgrades to a weaker cipher: if the requested cipher is
  unavailable, construction throws.
- No key contents, value contents, passphrases or derived key material are
  logged at any level. `ReaxEntry.toString()` and
  `DatabaseChangeEvent.toString()` are redacted.

### Fixed — error handling

- Nothing is swallowed into `null` or an empty result. Corruption, decode
  failures and unsupported input throw typed exceptions.
- Stubs that returned empty results were deleted rather than shipped.

### Added

- **Typed collections without code generation**: `db.collection<T>(name,
  fromJson:, toJson:)` with `put`, `putAll`, `get`, `delete`, `exists`, `all`,
  `where`, `find`, `count`, `createIndex` and a typed `watch`.
- **Real iteration**: `scan`, `scanPrefix`, `keys` and `range` on the public
  API, backed by the engine's ordered scan.
- **TTL / expiry**: per-key `ttl:` and `expiresAt:` honoured on read (an
  expired entry is absent), reclaimed lazily on read and eagerly with
  `purgeExpired()`. The cache honours the same instant.
- **Compound indexes**: `createIndex(collection, [fieldA, fieldB])`.
- **Backup and restore**: `db.exportTo(path)` and `ReaxDB.importFrom(...)` —
  point-in-time snapshot, magic number, format version, SHA-256 digest
  verified on import, index definitions carried across. Records are stored
  decrypted so a backup can be restored under different encryption.
- **Schema versions and migrations**: `schemaVersion` plus
  `onUpgrade(from, to, db)`, stored in the database header. Downgrades throw
  `SchemaVersionException`.
- **Instance registry and cross-process lock**: a second open of the same path
  throws `DatabaseLockedException`; across processes an OS advisory lock on
  `<path>/LOCK` is used, which the OS releases on process death, so stale
  locks cannot occur.
- **Sync modes**: `SyncMode.none/os/full` per database and a per-write `sync:`
  override that can only strengthen durability.
- `InvalidKeyException` for empty and reserved keys.
- `db.purgeExpired()`, `db.flush()`, `db.compact()`, `ReaxDB.closeAll()`.
- Per-instance loggers with redaction helpers; file logging is exported from
  `package:reaxdb_dart/reaxdb_dart_io.dart` so the main barrel stays free of
  it.
- Fault-injection and concurrency test suites: simulated crash, torn WAL tail,
  mid-file CRC corruption, partial SSTable, crash mid-compaction,
  replay-twice idempotence, crash mid-commit, and a 10k random-key
  write/flush/compact/reopen round trip.

### Removed

- The dual-write "hybrid" storage engine and the B-tree half of it.
- `enhanced_transaction.dart`.
- The XOR "AES fallback".
- The simple API key registry.
- The `21,000+ writes/sec` headline and the third-party device comparisons in
  the documentation. `BENCHMARKS.md` is now generated from a reproducible
  harness that states the machine and methodology.
- Documentation for APIs that never existed (`ReaxDB.open(encryptionType:)`,
  `MemoryLogOutput(maxLines:)`, enhanced-transaction callbacks).

## [1.4.1] - 2025-09-25

### Changed
- Updated GitHub repository URL from `ReaxBD` to `Reax-BD`
- Enhanced README to emphasize open source nature of the project
- Added comprehensive contributing guidelines
- Updated all documentation links to new repository URL

### Added
- Open source badges (MIT License, PRs Welcome, Open Source Love)
- Detailed contribution section with guidelines for community participation
- Contributors section for acknowledging community contributions

## [1.4.0] - 2025-08-20

### Added
- **Simple API**: New `ReaxDB.simple()` and `ReaxDB.quickStart()` methods for easy database setup
  - Start with just 3 lines of code
  - Automatic configuration with optimized defaults
  - No breaking changes - fully backward compatible
  - Simplified methods: `put()`, `get()`, `delete()`, `query()`, `watch()`
  - Access to advanced features via `.advanced` property
- **Improved Persistence**: Fixed key tracking in Simple API for proper data persistence between sessions
- **Integrated Demo App**: Example app now includes 4 comprehensive demos:
  - Performance demo (existing stress tests)
  - Simple CRUD demo
  - Todo app demo
  - Real-time chat demo
- **Real Benchmarks**: Updated performance benchmarks with actual measured data
  - 111,111 ops/sec for reads
  - 14,493 ops/sec for sequential writes
  - 71,429 ops/sec for batch writes
  - Comparison with Hive and Isar based on real data

### Changed
- **Documentation Restructure**:
  - Simplified README from 528 to 205 lines focusing on ease of use
  - Moved advanced features to separate `ADVANCED.md`
  - Added `MIGRATION.md` with guides for migrating from Hive/Isar/SQLite
  - Updated `BENCHMARKS.md` with real performance data
- **Better Developer Experience**:
  - Clear positioning: "The simplest way to store data in Dart & Flutter"
  - Focus on getting started quickly
  - Progressive disclosure of advanced features

### Fixed
- Simple API now properly persists keys metadata between sessions
- Example app navigation and demo integration
- Test coverage for Simple API (28 tests, all passing)

### Developer Experience
- Zero to functional in 3 lines of code
- No configuration required for basic usage
- Smooth learning curve from simple to advanced features
- Better documentation organization for different skill levels

## [1.3.0] - 2025-08-11

### Changed
- **Pure Dart Package**: Converted from Flutter-specific to pure Dart package - no longer requires Flutter SDK
- Package can now be used in any Dart environment (CLI, server, web, Flutter)
- **Note**: This is NOT a breaking change - all existing Flutter code continues to work

### Added
- **Configurable Logging System**: Multi-level logging with console, file, and memory outputs
- **Reactive Streams**: Advanced stream operators including:
  - `debounce()` - Delay events until a pause in emissions
  - `throttle()` - Limit event frequency
  - `buffer()` - Collect multiple events before emitting
  - `take()` and `skip()` - Control number of events
  - `map()` - Transform event data
- **Enhanced Query Builder**:
  - Aggregation functions: COUNT, SUM, AVG, MIN, MAX, DISTINCT
  - GROUP BY operations with multiple aggregations
  - Full-text search capabilities
  - Batch update operations
  - Batch delete operations
  - Improved scanning for large datasets (up to 1000 IDs)
- **Advanced Transaction Features**:
  - Transaction isolation levels (ReadUncommitted, ReadCommitted, RepeatableRead, Serializable)
  - Read-only transactions with write protection
  - Savepoints for partial rollback
  - Nested transactions
  - Automatic retry logic with exponential backoff
  - Transaction timeout support
  - Transaction statistics and monitoring
- **Enhanced Transaction Manager**:
  - `withTransaction()` - Automatic transaction management with retry
  - `beginEnhancedTransaction()` - Create transactions with advanced features
  - `beginReadOnlyTransaction()` - Create read-only transactions
  - Active transaction tracking
  - Bulk transaction closure

### Improved
- **Query Performance**: Extended collection scanning from 20 to 1000 IDs
- **Test Coverage**: Added comprehensive tests for all new features
- **API Documentation**: Enhanced documentation with examples for new features
- **Error Handling**: Better error messages and transaction failure handling

### Fixed
- Transaction retry logic now properly implements exponential backoff
- Query aggregation test expectations corrected
- Enhanced transaction tests now pass 100%

### Acknowledgments
- Special thanks to [@omtodkar](https://github.com/omtodkar) for the pure Dart conversion (PR #4)

## [1.2.3] - 2025-07-20

### Fixed
- **CRITICAL**: Fixed data persistence between application sessions
- WAL recovery now properly restores data on database reopening
- Fixed async operations in WAL write operations
- Fixed operation ordering to maintain data consistency
- Improved tombstone handling for deleted entries

### Acknowledgments
- Thanks to Ray Caruso for reporting the critical persistence bug

## [1.2.2] - 2025-07-15

### Fixed
- Fixed pub.dev static analysis issues
- Better error handling in code
- Improved code quality

### Added
- API documentation for all public methods

## [1.2.1] - 2025-07-15

### Fixed
- Minor fixes and code improvements

## [1.2.0] - 2025-07-11

### Added
- **WASM Compatibility**: Full support for Dart's WASM runtime with automatic fallback encryption
- **Enhanced Encryption API**: New `EncryptionType` enum for better encryption control
- **Encryption Factory Methods**: `DatabaseConfig.withXorEncryption()` and `DatabaseConfig.withAes256Encryption()`
- **WASM Fallback Encryption**: HMAC-based encryption for WASM environments when PointyCastle is unavailable
- **Runtime Detection**: Automatic detection of WASM runtime with appropriate warnings
- **Encryption Metadata**: Enhanced metadata including runtime environment and fallback status

### Improved
- **AES-256 Performance**: 40% faster AES encryption (138-180ms vs 237ms) using PointyCastle 4.0.0
- **WAL Recovery**: Fixed Write-Ahead Log recovery issues with proper pending write flushing
- **Code Documentation**: Updated README with new encryption API examples and WASM compatibility section

### Fixed
- **WAL Test Failures**: Resolved race conditions in Write-Ahead Log tests
- **Tombstone Recovery**: Fixed delete entry recovery in WAL mixed operations
- **Async Flush Issues**: Improved pending write flushing in WAL close operations

### Technical
- **Conditional Imports**: Smart import system for WASM compatibility
- **Fallback Implementation**: WASM-compatible encryption using only Dart's built-in crypto library
- **API Compatibility**: Maintains backward compatibility while adding new features

## [1.1.1] - 2025-06-15

### Added
- **Secondary Indexes**: Query any field with lightning speed
- **Query Builder**: Powerful API for complex queries  
- **Range Queries**: Find documents between values
- **Auto Index Updates**: Indexes stay in sync automatically

### Improved
- **Query Performance**: Significant improvements in indexed queries
- **Index Management**: Better index creation and maintenance

## [1.0.1] - 2025-05-20

### Added
- **4.4x faster writes**: Now 21,000+ operations per second
- **40% faster batch operations**: Improved batch processing

### Improved
- **Write Performance**: Major optimizations in write operations
- **Batch Processing**: Enhanced batch operation efficiency

## [1.0.0] - 2025-05-01

### Added
- Initial release of ReaxDB
- **High Performance**: Zero-copy serialization and multi-level caching system
- **Security**: Built-in encryption with customizable keys
- **ACID Transactions**: Full transaction support with isolation levels
- **Concurrent Operations**: Connection pooling and batch processing
- **Mobile Optimized**: Hybrid storage engine designed for mobile devices
- **Real-time Streams**: Live data change notifications with pattern matching
