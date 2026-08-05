/// The ReaxDB database facade.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'collection.dart';
import 'core/cache/multi_level_cache.dart';
import 'core/encryption/encryption_config.dart';
import 'core/encryption/encryption_engine.dart';
import 'core/encryption/encryption_type.dart';
import 'core/encryption/key_derivation.dart';
import 'core/errors/exceptions.dart';
import 'core/indexing/index_manager.dart';
import 'core/indexing/secondary_index.dart';
import 'core/logging/log_level.dart';
import 'core/logging/log_output.dart';
import 'core/logging/logger.dart';
import 'core/logging/redaction.dart';
import 'core/query/document_store.dart';
import 'core/query/query_builder.dart';
import 'core/storage/lsm_storage_engine.dart';
import 'core/storage/storage_engine.dart';
import 'core/streams/reactive_stream.dart';
import 'core/transactions/transaction_manager.dart';
import 'core/util/record_codec.dart' show Crc32;
import 'core/util/value_codec.dart';
import 'core/util/varint.dart';
import 'core/wal/write_ahead_log.dart' show SyncMode;
import 'domain/entities/database_entity.dart';
import 'legacy/legacy_migrator.dart';
import 'simple_api.dart';

/// How [ReaxDB.open] reacts to a ReaxDB 1.x database in the target directory.
///
/// A 1.x directory is recognised by [LegacyMigration.detect]; see
/// `MIGRATION.md` for the full upgrade guide.
enum LegacyMigrationMode {
  /// Refuse to open and explain how to migrate.
  ///
  /// The default. Finding 1.x files throws [SchemaVersionException] with a
  /// message naming the exact call to make, including the encrypted case.
  /// ReaxDB never rewrites a user's data without being asked to.
  detect,

  /// Migrate the 1.x database in place on open.
  ///
  /// The original files are preserved in a backup directory (never deleted),
  /// the data is written into a fresh 2.0 database at the same path, and the
  /// [MigrationReport] — including any anomaly warnings — is logged at info
  /// level before [ReaxDB.open] returns.
  automatic,

  /// Ignore 1.x files entirely.
  ///
  /// The 2.0 engine opens at the same path and sees an empty database; the
  /// 1.x files are left untouched on disk.
  off,
}

/// A ReaxDB database instance.
///
/// ## The single write pipeline (class invariant)
///
/// EVERY mutation this class performs — [put], [putBatch], [delete],
/// [deleteBatch], typed collection writes, query-driven `update`/`delete`,
/// TTL reclamation and post-commit maintenance for transactions — flows
/// through one private method, `_applyMutations`. That method applies, in
/// this exact order:
///
/// 1. build the write ops: the document/value op plus every secondary index
///    op returned by `IndexManager.buildIndexOps`;
/// 2. `StorageEngine.writeBatch(ops)` — the WAL append inside it is the
///    DURABILITY POINT; nothing observable happens before it succeeds;
/// 3. optional durability escalation for a per-write sync override;
/// 4. cache update or invalidation (plaintext record envelopes only, never
///    ciphertext, and never before step 2 — a failed write can therefore
///    never leave a phantom cache entry);
/// 5. change-event publication on the [ChangeStreamHub].
///
/// No other code path in this library writes to the storage engine on behalf
/// of a user mutation. Transactions are the one two-phase case: the
/// transaction manager owns the atomic batch (steps 1-2 for the document
/// values), and this class runs index maintenance, cache invalidation and
/// event publication from the returned [CommitResult] immediately afterwards.
/// Index updates for transactional writes are therefore durable in a second
/// batch that follows the commit, not in the same one; see `MIGRATION.md`.
///
/// ## Key space
///
/// Keys are UTF-8 byte strings. Byte `0x00` is reserved as the first byte of
/// ReaxDB's internal key space (secondary index postings and index
/// metadata), so a user key must not start with it; such keys are rejected
/// with [InvalidKeyException]. Documents addressed by the query layer use the
/// `collection:id` key shape.
final class ReaxDB {
  ReaxDB._({
    required String path,
    required LsmStorageEngine storage,
    required ReaxCache cache,
    required TransactionManager transactions,
    required IndexManager indexes,
    required EncryptionEngine encryption,
    required ChangeStreamHub hub,
    required ReaxLogger logger,
    required SyncMode syncMode,
    required RandomAccessFile lockFile,
    required _DatabaseHeader header,
  }) : _path = path,
       _storage = storage,
       _cache = cache,
       _transactions = transactions,
       _indexes = indexes,
       _encryption = encryption,
       _hub = hub,
       _logger = logger,
       _syncMode = syncMode,
       _lockFile = lockFile,
       _header = header;

  /// Instances open in this isolate, keyed by canonical directory path.
  static final Map<String, ReaxDB> _instances = <String, ReaxDB>{};

  /// Name of the on-disk lock file inside a database directory.
  static const String lockFileName = 'LOCK';

  /// Name of the database header file inside a database directory.
  static const String headerFileName = 'reaxdb.meta';

  final String _path;
  final LsmStorageEngine _storage;
  final ReaxCache _cache;
  final TransactionManager _transactions;
  final IndexManager _indexes;
  final EncryptionEngine _encryption;
  final ChangeStreamHub _hub;
  final ReaxLogger _logger;
  final SyncMode _syncMode;
  final RandomAccessFile _lockFile;

  _DatabaseHeader _header;
  bool _closed = false;
  bool _closing = false;

  /// Serializes pipeline writes against snapshot operations (export,
  /// compaction, flush, close) so a snapshot scan can never race a
  /// compaction that deletes the files it is reading.
  final _Mutex _ioMutex = _Mutex();

  /// Futures for work accepted but not yet finished, drained by [close].
  final Set<Future<void>> _inFlight = <Future<void>>{};

  late final DocumentStore _documentStore = _FacadeDocumentStore(this);

  // -- opening ------------------------------------------------------------

  /// Opens (or creates) the database stored in the directory [path].
  ///
  /// [encryption] selects the cipher applied to stored values; see
  /// [EncryptionConfig]. For a passphrase configuration a random PBKDF2 salt
  /// is generated on first open and persisted in the database header
  /// together with the iteration count, so later opens derive the same key.
  ///
  /// [syncMode] is the default durability level of every write;
  /// [SyncMode.full] fsyncs the write-ahead log before a write is
  /// acknowledged. Individual writes may request a stronger mode.
  ///
  /// [schemaVersion] is recorded in the header. Opening a database whose
  /// stored version is HIGHER than [schemaVersion] throws
  /// [SchemaVersionException] (no downgrades). Opening one whose stored
  /// version is lower runs [onUpgrade] with the stored and requested
  /// versions and the open database, then records the new version; when no
  /// [onUpgrade] is supplied an upgrade throws [SchemaVersionException]
  /// rather than silently reinterpreting old data.
  ///
  /// Throws [DatabaseLockedException] when the same path is already open in
  /// this isolate or locked by another process.
  ///
  /// ## ReaxDB 1.x databases
  ///
  /// [legacyMigration] decides what happens when the directory holds a
  /// database written by ReaxDB 1.x; the default
  /// [LegacyMigrationMode.detect] refuses to open and explains how to
  /// migrate. [legacyEncryptionKey] is the raw key string that was passed to
  /// the 1.x `ReaxDB.open(..., encryptionKey: ...)`, and is needed only to
  /// migrate an encrypted 1.x database.
  ///
  /// ## ReaxDB 1.x call shape (deprecated)
  ///
  /// The [config] and [encryptionKey] parameters exist so 1.x code keeps
  /// compiling; they are mapped onto the 2.0 options and will be removed in
  /// 3.0. When [config] is supplied its values win over the 2.0 defaults for
  /// the knobs that still exist, so do not mix it with the 2.0 parameters it
  /// covers. The 1.x POSITIONAL database name is accepted by [openLegacy]
  /// instead of here, because Dart does not allow a method to take both an
  /// optional positional parameter and named ones. See `MIGRATION.md`.
  static Future<ReaxDB> open({
    required String path,
    EncryptionConfig encryption = const EncryptionConfig.none(),
    SyncMode syncMode = SyncMode.full,
    int memtableSizeBytes = 4 * 1024 * 1024,
    int cacheMaxEntries = 10000,
    int cacheMaxMemoryBytes = 64 * 1024 * 1024,
    Duration? cacheDefaultTtl,
    LogLevel logLevel = LogLevel.warning,
    List<LogOutput>? logOutputs,
    String? loggerName,
    IsolationLevel defaultIsolationLevel = IsolationLevel.readCommitted,
    Duration lockTimeout = const Duration(seconds: 10),
    int schemaVersion = 1,
    FutureOr<void> Function(int from, int to, ReaxDB db)? onUpgrade,
    LegacyMigrationMode legacyMigration = LegacyMigrationMode.detect,
    String? legacyEncryptionKey,
    @Deprecated(
      'Use the 2.0 named parameters of ReaxDB.open (syncMode, '
      'memtableSizeBytes, cacheMaxEntries, ...). Removed in 3.0.',
    )
    // ignore: deprecated_member_use_from_same_package
    DatabaseConfig? config,
    @Deprecated(
      'Use encryption: EncryptionConfig.aes256FromPassphrase(passphrase: ...) '
      'or EncryptionConfig.aes256(key: ...). Removed in 3.0.',
    )
    String? encryptionKey,
  }) async {
    if (schemaVersion < 1) {
      throw SchemaVersionException(
        'schemaVersion must be at least 1 (got $schemaVersion)',
        expectedVersion: schemaVersion,
      );
    }
    final EncryptionConfig effectiveEncryption = _resolveLegacyEncryption(
      // ignore: deprecated_member_use_from_same_package
      config: config,
      encryptionKey: encryptionKey,
      encryption: encryption,
    );
    // ignore: deprecated_member_use_from_same_package
    final _TuningOverrides tuning = _TuningOverrides.from(config);
    final SyncMode effectiveSyncMode = tuning.syncMode ?? syncMode;
    final int effectiveMemtableSizeBytes =
        tuning.memtableSizeBytes ?? memtableSizeBytes;
    final int effectiveCacheMaxEntries =
        tuning.cacheMaxEntries ?? cacheMaxEntries;

    final Directory directory = Directory(path);
    await directory.create(recursive: true);
    final String canonical = _canonicalize(path);

    if (_instances.containsKey(canonical)) {
      throw DatabaseLockedException(
        'Database at "$canonical" is already open in this isolate. Close the '
        'existing ReaxDB instance before opening it again.',
        path: canonical,
      );
    }

    // The 1.x check runs before the lock is taken because an automatic
    // migration opens a 2.0 database at this very path through the public
    // API, which acquires the lock itself.
    final MigrationReport? migrationReport = await _handleLegacyDatabase(
      canonical: canonical,
      mode: legacyMigration,
      legacyEncryptionKey: legacyEncryptionKey,
      encryption: effectiveEncryption,
    );

    final RandomAccessFile lockFile = await _acquireLock(canonical);
    ReaxLogger? logger;
    LsmStorageEngine? storage;
    try {
      logger = ReaxLogger(
        level: logLevel,
        outputs: logOutputs,
        name: loggerName ?? p.basename(canonical),
      );

      final _DatabaseHeader header = await _DatabaseHeader.load(
        canonical,
        effectiveEncryption,
        schemaVersion,
      );

      final EncryptionEngine engine = EncryptionEngine(
        effectiveEncryption,
        kdfSalt: header.kdfSalt,
      );

      storage = await LsmStorageEngine.open(
        directory: canonical,
        syncMode: effectiveSyncMode,
        memtableSizeBytes: effectiveMemtableSizeBytes,
      );

      final ReaxCache cache = ReaxCache(
        maxEntries: effectiveCacheMaxEntries,
        maxMemoryBytes: cacheMaxMemoryBytes,
        defaultTtl: cacheDefaultTtl,
      );

      final ReaxDB db = ReaxDB._(
        path: canonical,
        storage: storage,
        cache: cache,
        transactions: TransactionManager(
          storageEngine: storage,
          defaultIsolationLevel: defaultIsolationLevel,
          lockTimeout: lockTimeout,
        ),
        indexes: IndexManager(
          storage: storage,
          decodeDocument:
              (Uint8List bytes) => _decodeStoredDocument(bytes, engine),
        ),
        encryption: engine,
        hub: ChangeStreamHub(),
        logger: logger,
        syncMode: effectiveSyncMode,
        lockFile: lockFile,
        header: header,
      );

      await db._indexes.loadIndexes();
      _instances[canonical] = db;

      if (header.schemaVersion != schemaVersion) {
        await db._runUpgrade(header.schemaVersion, schemaVersion, onUpgrade);
      }
      if (migrationReport != null) {
        await logger.info(_describeMigration(migrationReport));
      }
      await logger.info('Database opened at $canonical');
      return db;
    } catch (_) {
      await storage?.close();
      await logger?.close();
      _instances.remove(canonical);
      await _releaseLock(lockFile);
      rethrow;
    }
  }

  // -- ReaxDB 1.x migration ------------------------------------------------

  /// Applies [mode] to a possible 1.x database at [canonical].
  ///
  /// Returns the report of an automatic migration, or null when there was
  /// nothing to migrate.
  static Future<MigrationReport?> _handleLegacyDatabase({
    required String canonical,
    required LegacyMigrationMode mode,
    required String? legacyEncryptionKey,
    required EncryptionConfig encryption,
  }) async {
    if (mode == LegacyMigrationMode.off) return null;
    final LegacyDatabaseInfo? legacy = await LegacyMigration.detect(canonical);
    if (legacy == null) return null;
    if (mode == LegacyMigrationMode.detect) {
      throw SchemaVersionException(_legacyDetectedMessage(legacy));
    }
    return LegacyMigration.migrate(
      sourcePath: canonical,
      targetPath: canonical,
      legacyEncryptionKey: legacyEncryptionKey,
      encryption: encryption,
    );
  }

  /// The message [LegacyMigrationMode.detect] throws: it must be enough to
  /// act on without reading the documentation first.
  static String _legacyDetectedMessage(LegacyDatabaseInfo legacy) =>
      'The directory "${legacy.path}" holds a ReaxDB '
      '${legacy.detectedVersion} database '
      '(${legacy.sstableFileCount} SSTable files, ${legacy.walFileCount} WAL '
      'files, about ${legacy.estimatedEntryCount} entries'
      '${legacy.looksEncrypted ? ', and it looks encrypted' : ''}). '
      'ReaxDB 2.0 uses a different on-disk format and will not rewrite your '
      'data without being asked to. Choose one:\n'
      '  1. Migrate once, keeping a backup of the 1.x files:\n'
      '       await ReaxDB.migrateFrom1x(sourcePath: "${legacy.path}");\n'
      '  2. Or migrate on open:\n'
      '       ReaxDB.open(path: "${legacy.path}", legacyMigration: '
      'LegacyMigrationMode.automatic)\n'
      '${legacy.looksEncrypted ? '  Because the 1.x database is encrypted, '
              'also pass the ORIGINAL 1.x key as legacyEncryptionKey: "..." '
              'and the NEW configuration in encryption:.\n' : ''}'
      '  3. Or ignore the 1.x files and start empty at this path:\n'
      '       ReaxDB.open(path: "${legacy.path}", legacyMigration: '
      'LegacyMigrationMode.off)\n'
      'Migration never deletes the 1.x files; they are preserved in a backup '
      'directory. See MIGRATION.md.';

  /// One-line summary of [report], logged after an automatic migration.
  static String _describeMigration(MigrationReport report) =>
      'Migrated a ReaxDB 1.x database: ${report.entriesMigrated} entries '
      'migrated, ${report.entriesSkipped} skipped, '
      '${report.tombstonesApplied} tombstones applied in '
      '${report.elapsed.inMilliseconds}ms. Backup: ${report.backupPath}.'
      '${report.warnings.isEmpty ? '' : ' Warnings: '
              '${report.warnings.join('; ')}'}';

  /// Migrates the ReaxDB 1.x database at [sourcePath] into a 2.0 database.
  ///
  /// [targetPath] defaults to [sourcePath] (migration in place). The 1.x
  /// files are never deleted: they are preserved in a backup directory named
  /// in [MigrationReport.backupPath].
  ///
  /// [legacyEncryptionKey] is the raw key string that was passed to the 1.x
  /// `ReaxDB.open(..., encryptionKey: ...)`, and is required only when the
  /// source is encrypted. [encryption] configures the NEW database; the
  /// migrated copy is re-encrypted with the 2.0 scheme (PBKDF2 with a random
  /// per-database salt, AES-256-GCM with a random IV per value). The 1.x key
  /// derivation is used for reading only and never protects new data.
  ///
  /// Migration reproduces faithfully what 1.x wrote. It cannot repair data
  /// that 1.x itself lost or corrupted; anomalies it can see are reported in
  /// [MigrationReport.warnings]. See `MIGRATION.md`.
  static Future<MigrationReport> migrateFrom1x({
    required String sourcePath,
    String? targetPath,
    String? legacyEncryptionKey,
    EncryptionConfig encryption = const EncryptionConfig.none(),
    void Function(int migrated, int total)? onProgress,
  }) => LegacyMigration.migrate(
    sourcePath: sourcePath,
    targetPath: targetPath ?? sourcePath,
    legacyEncryptionKey: legacyEncryptionKey,
    encryption: encryption,
    onProgress: onProgress,
  );

  /// Describes the ReaxDB 1.x database at [path], or null when [path] is not
  /// one (it is already a 2.0 database, empty, or unrecognised).
  static Future<LegacyDatabaseInfo?> inspect1x(String path) =>
      LegacyMigration.detect(path);

  // -- 1.x compatibility ---------------------------------------------------

  /// The ReaxDB 1.x `open` call shape: a positional database name plus
  /// [config], [encryptionKey] and [path].
  ///
  /// Dart does not allow one method to take both an optional positional
  /// parameter and named parameters, so the 1.x shape could not be folded
  /// into [open]. Porting is a one-token edit:
  ///
  /// ```dart
  /// // 1.x
  /// final db = await ReaxDB.open('myapp', config: config, path: 'data');
  /// // 2.0, unchanged semantics
  /// final db = await ReaxDB.openLegacy('myapp', config: config, path: 'data');
  /// // 2.0, preferred
  /// final db = await ReaxDB.open(path: 'data', syncMode: SyncMode.full);
  /// ```
  ///
  /// The directory is `path ?? name`, exactly as in 1.x. [config] and
  /// [encryptionKey] map onto the 2.0 options; see [DatabaseConfig]. An
  /// [encryptionKey] derives a real key (PBKDF2 with a random stored salt),
  /// which is deliberately NOT the 1.x derivation, so this cannot open a 1.x
  /// database in place — migrate it, with [legacyMigration].
  @Deprecated('Use ReaxDB.open(path: ...). Removed in 3.0.')
  static Future<ReaxDB> openLegacy(
    String name, {
    // ignore: deprecated_member_use_from_same_package
    DatabaseConfig? config,
    String? encryptionKey,
    String? path,
    LegacyMigrationMode legacyMigration = LegacyMigrationMode.detect,
    String? legacyEncryptionKey,
  }) => open(
    path: path ?? name,
    loggerName: name,
    legacyMigration: legacyMigration,
    legacyEncryptionKey: legacyEncryptionKey,
    // ignore: deprecated_member_use_from_same_package
    config: config,
    // ignore: deprecated_member_use_from_same_package
    encryptionKey: encryptionKey,
  );

  /// Maps the deprecated 1.x encryption parameters onto an [EncryptionConfig].
  ///
  /// A key given here always derives a real key: PBKDF2-HMAC-SHA256 with a
  /// random salt stored in the database header. This is deliberately NOT what
  /// 1.x did (10,001 rounds of SHA-256 with one hardcoded salt shared by
  /// every database), so a database created this way is not byte-compatible
  /// with 1.x — existing 1.x data must be migrated, not reopened.
  static EncryptionConfig _resolveLegacyEncryption({
    // ignore: deprecated_member_use_from_same_package
    required DatabaseConfig? config,
    required String? encryptionKey,
    required EncryptionConfig encryption,
  }) {
    if (config == null && encryptionKey == null) return encryption;
    if (encryption is! NoEncryptionConfig) {
      throw const UnsupportedApiException(
        'ReaxDB.open was given both the 2.0 encryption: configuration and the '
        'deprecated 1.x config:/encryptionKey: parameters. Pass only '
        'encryption:.',
      );
    }
    // ignore: deprecated_member_use_from_same_package
    final EncryptionType type = config?.encryptionType ?? EncryptionType.none;
    if (type == EncryptionType.none && encryptionKey == null) {
      return const EncryptionConfig.none();
    }
    if (encryptionKey == null || encryptionKey.isEmpty) {
      throw EncryptionException(
        'The 1.x config requested ${type.name} encryption but no '
        'encryptionKey was given. Pass encryption: '
        'EncryptionConfig.aes256FromPassphrase(passphrase: ...) instead.',
      );
    }
    if (type == EncryptionType.obfuscation) {
      return EncryptionConfig.obfuscation(
        key: Uint8List.fromList(utf8.encode(encryptionKey)),
      );
    }
    // A key without an explicit type (or with aes256) means AES-256: 1.x
    // stored plaintext in that case, but silently storing plaintext when the
    // caller handed us a key is not a defensible default.
    return EncryptionConfig.aes256FromPassphrase(passphrase: encryptionKey);
  }

  /// Opens a database with a simplified API and safe defaults.
  ///
  /// Unlike ReaxDB 1.x this NEVER derives an encryption key from [name]; to
  /// encrypt a simple database pass a real [EncryptionConfig]. The
  /// deprecated 1.x [encrypted] flag therefore throws [EncryptionException]
  /// when it is true.
  static Future<SimpleReaxDB> simple(
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
  }) => SimpleReaxDB.open(
    name,
    path: path,
    encryption: encryption,
    syncMode: syncMode,
    // ignore: deprecated_member_use_from_same_package
    encrypted: encrypted,
  );

  /// The ReaxDB 1.x shortcut for [simple].
  @Deprecated('Use ReaxDB.simple(name). Removed in 3.0.')
  static Future<SimpleReaxDB> quickStart(String name) => simple(name);

  Future<void> _runUpgrade(
    int from,
    int to,
    FutureOr<void> Function(int from, int to, ReaxDB db)? onUpgrade,
  ) async {
    if (to < from) {
      throw SchemaVersionException(
        'Database at "$_path" was written with schema version $from and '
        'cannot be opened with the older version $to. Export the data with '
        'exportTo() using the newer schema and import it into a fresh '
        'database.',
        storedVersion: from,
        expectedVersion: to,
      );
    }
    if (onUpgrade == null) {
      throw SchemaVersionException(
        'Database at "$_path" is at schema version $from but version $to was '
        'requested and no onUpgrade callback was supplied.',
        storedVersion: from,
        expectedVersion: to,
      );
    }
    await _logger.info('Migrating schema from $from to $to');
    await onUpgrade(from, to, this);
    _header = _header.withSchemaVersion(to);
    await _header.save(_path);
  }

  // -- accessors ----------------------------------------------------------

  /// Absolute path of the database directory.
  String get path => _path;

  /// Schema version currently recorded in the database header.
  int get schemaVersion => _header.schemaVersion;

  /// Default durability level applied to writes.
  SyncMode get syncMode => _syncMode;

  /// Whether [close] has completed.
  bool get isClosed => _closed;

  /// This database's logger. Closed by [close].
  ReaxLogger get logger => _logger;

  /// Metadata describing the EFFECTIVE encryption configuration.
  Map<String, dynamic> get encryptionInfo => _encryption.getMetadata();

  /// Live cache statistics.
  CacheStatistics get cacheStats => _cache.stats;

  /// Live transaction statistics.
  TransactionStats get transactionStats => _transactions.stats;

  /// Live storage engine counters.
  StorageStats get storageStats => _storage.stats;

  void _ensureOpen() {
    if (_closed || _closing) {
      throw DatabaseClosedException('Database at "$_path" is closed');
    }
  }

  Future<T> _track<T>(Future<T> Function() body) {
    final Future<T> result = body();
    late final Future<void> guard;
    guard = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _inFlight.remove(guard);
    });
    _inFlight.add(guard);
    return result;
  }

  // -- keys and values ----------------------------------------------------

  /// Encodes a user key, rejecting the reserved internal key space.
  static Uint8List encodeKey(String key) {
    if (key.isEmpty) {
      throw const InvalidKeyException('Database keys must not be empty');
    }
    final Uint8List bytes = Uint8List.fromList(utf8.encode(key));
    if (bytes[0] == 0x00) {
      throw InvalidKeyException(
        'Key ${Redaction.key(key)} starts with the reserved byte 0x00, which '
        'is used by ReaxDB internal keys',
      );
    }
    return bytes;
  }

  /// Decodes stored bytes into the plaintext record envelope.
  Uint8List _toEnvelope(Uint8List stored) => _encryption.decrypt(stored);

  /// Encrypts a plaintext record envelope for storage.
  Uint8List _toStored(Uint8List envelope) => _encryption.encrypt(envelope);

  static Map<String, dynamic>? _decodeStoredDocument(
    Uint8List stored,
    EncryptionEngine encryption,
  ) {
    try {
      final StoredRecord record = RecordEnvelope.decode(
        encryption.decrypt(stored),
      );
      if (record.isExpiredAt(DateTime.now())) return null;
      final Object? value = record.value;
      return value is Map<String, dynamic> ? value : null;
    } on ReaxDbException {
      // A non-document value (raw bytes, a string, an index posting) is not
      // an error here: it simply is not indexable.
      return null;
    }
  }

  // -- reads --------------------------------------------------------------

  /// Reads the value stored under [key], or null when absent or expired.
  ///
  /// An entry whose TTL has elapsed reads as absent and is reclaimed through
  /// the write pipeline (emitting a delete event) before this returns.
  Future<T?> get<T>(String key) async {
    _ensureOpen();
    final Uint8List keyBytes = encodeKey(key);
    final DateTime now = DateTime.now();

    final Uint8List? cached = _cache.get(key);
    if (cached != null) {
      final StoredRecord record = RecordEnvelope.decode(cached);
      if (!record.isExpiredAt(now)) return _cast<T>(key, record.value);
      _cache.remove(key);
    }

    final Uint8List? stored = await _storage.get(keyBytes);
    if (stored == null) return null;

    final Uint8List envelope = _toEnvelope(stored);
    final StoredRecord record = RecordEnvelope.decode(envelope);
    if (record.isExpiredAt(now)) {
      await _reclaimExpired(<String>[key]);
      return null;
    }
    _cache.put(key, envelope, expiresAt: record.expiresAt);
    return _cast<T>(key, record.value);
  }

  /// Reads several keys, returning null for those absent or expired.
  Future<Map<String, T?>> getBatch<T>(List<String> keys) async {
    _ensureOpen();
    final Map<String, T?> out = <String, T?>{};
    for (final String key in keys) {
      out[key] = await get<T>(key);
    }
    return out;
  }

  /// Whether a live (non-expired) entry exists for [key].
  Future<bool> exists(String key) async {
    _ensureOpen();
    final Uint8List? stored = await _storage.get(encodeKey(key));
    if (stored == null) return false;
    return !RecordEnvelope.isExpired(_toEnvelope(stored), DateTime.now());
  }

  static T? _cast<T>(String key, Object? value) {
    if (value == null) return null;
    if (value is T) return value as T;
    throw SerializationException(
      'Value stored under ${Redaction.key(key)} is a ${value.runtimeType}, '
      'which is not a $T',
    );
  }

  // -- iteration ----------------------------------------------------------

  /// Streams entries in key order.
  ///
  /// [startKey] is inclusive and [endKey] exclusive; null means unbounded.
  /// [limit] caps the number of entries yielded and [reverse] walks from high
  /// keys to low. Expired entries are skipped (use [purgeExpired] to reclaim
  /// their space). ReaxDB internal keys are never yielded.
  Stream<ReaxEntry<T>> scan<T>({
    String? startKey,
    String? endKey,
    int? limit,
    bool reverse = false,
  }) async* {
    _ensureOpen();
    yield* _scanRange<T>(
      startKey == null ? _userKeySpaceStart : encodeKey(startKey),
      endKey == null ? null : encodeKey(endKey),
      limit,
      reverse,
    );
  }

  /// Streams every entry whose key starts with [prefix].
  Stream<ReaxEntry<T>> scanPrefix<T>(
    String prefix, {
    int? limit,
    bool reverse = false,
  }) async* {
    _ensureOpen();
    final Uint8List start = encodeKey(prefix);
    yield* _scanRange<T>(
      start,
      IndexKeyCodec.prefixUpperBound(start),
      limit,
      reverse,
    );
  }

  /// Streams keys in order, optionally restricted to those starting with
  /// [prefix]. Values are not decoded.
  Stream<String> keys({
    String? prefix,
    int? limit,
    bool reverse = false,
  }) async* {
    _ensureOpen();
    final Uint8List start =
        prefix == null ? _userKeySpaceStart : encodeKey(prefix);
    final Uint8List? end =
        prefix == null ? null : IndexKeyCodec.prefixUpperBound(start);
    final DateTime now = DateTime.now();
    int yielded = 0;
    await for (final KeyValue pair in _storage.scan(
      startKey: start,
      endKey: end,
      reverse: reverse,
    )) {
      if (RecordEnvelope.isExpired(_toEnvelope(pair.value), now)) continue;
      if (limit != null && yielded >= limit) return;
      yielded++;
      yield utf8.decode(pair.key);
    }
  }

  /// Returns the entries with keys in `[startKey, endKey)`.
  Future<List<ReaxEntry<T>>> range<T>(
    String startKey,
    String endKey, {
    int? limit,
    bool reverse = false,
  }) =>
      scan<T>(
        startKey: startKey,
        endKey: endKey,
        limit: limit,
        reverse: reverse,
      ).toList();

  /// First byte of the user key space; everything below it is reserved.
  static final Uint8List _userKeySpaceStart = Uint8List.fromList(const <int>[
    0x01,
  ]);

  Stream<ReaxEntry<T>> _scanRange<T>(
    Uint8List start,
    Uint8List? end,
    int? limit,
    bool reverse,
  ) async* {
    final DateTime now = DateTime.now();
    int yielded = 0;
    await for (final KeyValue pair in _storage.scan(
      startKey: start,
      endKey: end,
      reverse: reverse,
    )) {
      final Uint8List envelope = _toEnvelope(pair.value);
      final StoredRecord record = RecordEnvelope.decode(envelope);
      if (record.isExpiredAt(now)) continue;
      if (limit != null && yielded >= limit) return;
      yielded++;
      final String key = utf8.decode(pair.key);
      yield ReaxEntry<T>(
        key: key,
        value: _cast<T>(key, record.value) as T,
        expiresAt: record.expiresAt,
      );
    }
  }

  // -- the single write pipeline -----------------------------------------

  /// The one place that mutates storage on behalf of a user write.
  ///
  /// See the class dartdoc for the ordering invariant this method enforces.
  Future<void> _applyMutations(
    List<_Mutation> mutations, {
    SyncMode? sync,
  }) async {
    if (mutations.isEmpty) return;
    await _ioMutex.run(() async {
      final List<WriteOp> ops = <WriteOp>[];

      // 1. Build the batch: value ops plus secondary index maintenance.
      for (final _Mutation mutation in mutations) {
        final Uint8List keyBytes = encodeKey(mutation.key);
        final _DocumentAddress? address = _DocumentAddress.parse(mutation.key);
        if (address != null &&
            _indexes.listIndexes(address.collection).isNotEmpty) {
          ops.addAll(
            await _indexes.buildIndexOps(
              collection: address.collection,
              docId: address.id,
              oldDoc: await _loadDocument(keyBytes),
              newDoc:
                  mutation.value is Map<String, dynamic>
                      ? mutation.value as Map<String, dynamic>
                      : null,
            ),
          );
        }
        ops.add(
          mutation.isDelete
              ? WriteOp.delete(keyBytes)
              : WriteOp.put(keyBytes, _toStored(mutation.envelope!)),
        );
      }

      // 2. Durability point.
      await _storage.writeBatch(ops);

      // 3. Optional per-write durability escalation.
      if (sync != null && sync.index > _syncMode.index) {
        await _storage.syncTo(sync);
      }

      // 4. Cache, only now that the data is durable.
      for (final _Mutation mutation in mutations) {
        if (mutation.isDelete) {
          _cache.remove(mutation.key);
        } else {
          _cache.put(
            mutation.key,
            mutation.envelope!,
            expiresAt: mutation.expiresAt,
          );
        }
      }

      // 5. Change events, only after the durability point.
      final DateTime now = DateTime.now();
      for (final _Mutation mutation in mutations) {
        _hub.publish(
          DatabaseChangeEvent(
            type: mutation.isDelete ? ChangeType.delete : ChangeType.put,
            key: mutation.key,
            value: mutation.isDelete ? null : mutation.value,
            timestamp: now,
          ),
        );
      }
    });
  }

  Future<Map<String, dynamic>?> _loadDocument(Uint8List keyBytes) async {
    final Uint8List? stored = await _storage.get(keyBytes);
    if (stored == null) return null;
    return _decodeStoredDocument(stored, _encryption);
  }

  /// Stores [value] under [key].
  ///
  /// [ttl] (relative) or [expiresAt] (absolute) make the entry expire; when
  /// both are given [expiresAt] wins. [sync] overrides the database's sync
  /// mode for this write when it is stronger than the default.
  ///
  /// Throws [InvalidKeyException] for a reserved or empty key and
  /// [SerializationException] when [value] cannot be encoded.
  Future<void> put(
    String key,
    Object? value, {
    Duration? ttl,
    DateTime? expiresAt,
    SyncMode? sync,
  }) {
    _ensureOpen();
    return _track(
      () => _applyMutations(<_Mutation>[
        _Mutation.put(key, value, _resolveExpiry(ttl, expiresAt)),
      ], sync: sync),
    );
  }

  /// Stores every pair of [entries] in one atomic batch.
  Future<void> putBatch(
    Map<String, Object?> entries, {
    Duration? ttl,
    DateTime? expiresAt,
    SyncMode? sync,
  }) {
    _ensureOpen();
    final DateTime? expiry = _resolveExpiry(ttl, expiresAt);
    return _track(
      () => _applyMutations(<_Mutation>[
        for (final MapEntry<String, Object?> e in entries.entries)
          _Mutation.put(e.key, e.value, expiry),
      ], sync: sync),
    );
  }

  /// Removes [key]. Deleting an absent key is a no-op that still emits an
  /// event, because the post-state (absent) is what observers care about.
  Future<void> delete(String key, {SyncMode? sync}) {
    _ensureOpen();
    return _track(
      () => _applyMutations(<_Mutation>[_Mutation.delete(key)], sync: sync),
    );
  }

  /// Removes every key in [keys] in one atomic batch.
  Future<void> deleteBatch(List<String> keys, {SyncMode? sync}) {
    _ensureOpen();
    return _track(
      () => _applyMutations(<_Mutation>[
        for (final String key in keys) _Mutation.delete(key),
      ], sync: sync),
    );
  }

  static DateTime? _resolveExpiry(Duration? ttl, DateTime? expiresAt) {
    if (expiresAt != null) return expiresAt;
    if (ttl != null) return DateTime.now().add(ttl);
    return null;
  }

  Future<void> _reclaimExpired(List<String> keys) => _applyMutations(
    <_Mutation>[for (final String key in keys) _Mutation.delete(key)],
  );

  /// Removes every entry whose TTL has elapsed and returns how many were
  /// reclaimed. Expired entries already read as absent; this reclaims their
  /// storage eagerly instead of waiting for the next read of each key.
  Future<int> purgeExpired() {
    _ensureOpen();
    return _track(() async {
      final DateTime now = DateTime.now();
      final List<String> expired = <String>[];
      await for (final KeyValue pair in _storage.scan(
        startKey: _userKeySpaceStart,
      )) {
        if (RecordEnvelope.isExpired(_toEnvelope(pair.value), now)) {
          expired.add(utf8.decode(pair.key));
        }
      }
      await _reclaimExpired(expired);
      return expired.length;
    });
  }

  // -- transactions -------------------------------------------------------

  /// Runs [body] in an ACID transaction, committing on success.
  ///
  /// The whole write set is applied atomically by the transaction manager.
  /// Retries on [TransactionConflictException] and [DeadlockException] up to
  /// [maxAttempts] times; any other error aborts and propagates. After the
  /// commit succeeds this method runs secondary index maintenance, cache
  /// invalidation and event publication for every applied operation.
  Future<T> transaction<T>(
    Future<T> Function(ReaxTransaction tx) body, {
    IsolationLevel? isolationLevel,
    int maxAttempts = 3,
  }) {
    _ensureOpen();
    return _track(() async {
      CommitResult? committed;
      final T value = await _transactions.runTransaction<T>(
        (Transaction tx) => body(ReaxTransaction._(this, tx)),
        isolationLevel: isolationLevel,
        maxAttempts: maxAttempts,
        onCommit: (CommitResult result) => committed = result,
      );
      final CommitResult? result = committed;
      if (result != null) await _postCommit(result);
      return value;
    });
  }

  /// Applies post-commit maintenance for a committed transaction.
  Future<void> _postCommit(CommitResult result) async {
    if (result.operations.isEmpty) return;
    await _ioMutex.run(() async {
      final List<WriteOp> indexOps = <WriteOp>[];
      final List<DatabaseChangeEvent> events = <DatabaseChangeEvent>[];
      final DateTime now = DateTime.now();

      for (final AppliedOperation op in result.operations) {
        final _DocumentAddress? address = _DocumentAddress.parse(op.key);
        final Uint8List? newBytes = op.newValue;
        final StoredRecord? record =
            newBytes == null
                ? null
                : RecordEnvelope.decode(_toEnvelope(newBytes));

        if (address != null &&
            _indexes.listIndexes(address.collection).isNotEmpty) {
          indexOps.addAll(
            await _indexes.buildIndexOps(
              collection: address.collection,
              docId: address.id,
              oldDoc:
                  op.oldValue == null
                      ? null
                      : _decodeStoredDocument(op.oldValue!, _encryption),
              newDoc:
                  record?.value is Map<String, dynamic>
                      ? record!.value as Map<String, dynamic>
                      : null,
            ),
          );
        }

        if (record == null) {
          _cache.remove(op.key);
        } else {
          _cache.put(
            op.key,
            _toEnvelope(newBytes!),
            expiresAt: record.expiresAt,
          );
        }
        events.add(
          DatabaseChangeEvent(
            type: record == null ? ChangeType.delete : ChangeType.put,
            key: op.key,
            value: record?.value,
            timestamp: now,
          ),
        );
      }

      if (indexOps.isNotEmpty) {
        await _storage.writeBatch(indexOps);
      }
      for (final DatabaseChangeEvent event in events) {
        _hub.publish(event);
      }
    });
  }

  /// Atomically sets [key] to [newValue] only if it currently holds
  /// [expectedValue], returning whether the swap happened.
  ///
  /// The comparison and the write run inside one serializable transaction,
  /// so no concurrent writer can slip between them.
  Future<bool> compareAndSwap<T>(
    String key,
    T? expectedValue,
    T newValue, {
    Duration? ttl,
    DateTime? expiresAt,
  }) {
    _ensureOpen();
    return transaction<bool>((ReaxTransaction tx) async {
      final T? current = await tx.get<T>(key);
      if (current != expectedValue) return false;
      await tx.put(key, newValue, ttl: ttl, expiresAt: expiresAt);
      return true;
    }, isolationLevel: IsolationLevel.serializable);
  }

  // -- collections, queries and indexes -----------------------------------

  /// Returns a typed view of [name] that stores instances of [T].
  ///
  /// No code generation is involved: [fromJson] and [toJson] are ordinary
  /// functions. Documents are stored under `name:id`, so they participate in
  /// queries and secondary indexes like untyped documents.
  ReaxCollection<T> collection<T>(
    String name, {
    required T Function(Map<String, dynamic> json) fromJson,
    required Map<String, dynamic> Function(T value) toJson,
  }) {
    _ensureOpen();
    return ReaxCollection<T>(
      name: name,
      db: this,
      fromJson: fromJson,
      toJson: toJson,
    );
  }

  /// Returns a query builder over the documents of [collection].
  QueryBuilder query(String collection) {
    _ensureOpen();
    return QueryBuilder(
      collection: collection,
      store: _documentStore,
      indexManager: _indexes,
    );
  }

  /// Shorthand for an equality query over [collection].
  Future<List<Map<String, dynamic>>> where(
    String collection,
    String field,
    Object? value,
  ) => query(collection).whereEquals(field, value).find();

  /// Creates a secondary index over [fields] of [collection] and backfills
  /// it from existing documents. A single-element list creates a plain
  /// index; two or more fields create a compound index in that significance
  /// order.
  Future<void> createIndex(String collection, List<String> fields) {
    _ensureOpen();
    return _track(() => _indexes.createCompoundIndex(collection, fields));
  }

  /// Drops the index over [fields] of [collection].
  Future<void> dropIndex(String collection, List<String> fields) {
    _ensureOpen();
    return _track(() => _indexes.dropIndex(collection, fields));
  }

  /// Whether an index exists whose leading field is [field].
  bool hasIndex(String collection, String field) {
    _ensureOpen();
    return _indexes.hasIndex(collection, field);
  }

  /// All index definitions, optionally restricted to [collection].
  List<IndexDefinition> listIndexes([String? collection]) {
    _ensureOpen();
    return _indexes.listIndexes(collection);
  }

  // -- change streams -----------------------------------------------------

  /// Streams change events whose key matches [pattern].
  ///
  /// `*` matches everything, `prefix*` matches by prefix, and any other
  /// pattern without `*` matches that exact key.
  Stream<DatabaseChangeEvent> watch(String pattern) {
    _ensureOpen();
    return _hub.watch(pattern);
  }

  /// Streams change events for exactly [key].
  Stream<DatabaseChangeEvent> watchKey(String key) => watch(key);

  /// Streams change events for keys starting with [prefix].
  Stream<DatabaseChangeEvent> watchPrefix(String prefix) => watch('$prefix*');

  /// Streams change events for the documents of [collection].
  Stream<DatabaseChangeEvent> watchCollection(String collection) =>
      watchPrefix('$collection:');

  /// A [ReactiveStream] over every change in the database.
  ReactiveStream get changes => ReactiveStream(watch('*'));

  // -- maintenance --------------------------------------------------------

  /// Persists the in-memory write buffer to disk and checkpoints the WAL.
  Future<void> flush() {
    _ensureOpen();
    return _track(() => _ioMutex.run(_storage.flush));
  }

  /// Compacts the on-disk tables, reclaiming space from overwritten and
  /// deleted keys.
  Future<void> compact() {
    _ensureOpen();
    return _track(() => _ioMutex.run(_storage.compact));
  }

  /// Returns a description of this database.
  ///
  /// [DatabaseInfo.entryCount] is computed by iterating live user entries, so
  /// this is O(entries); the other fields are counters.
  Future<DatabaseInfo> info() async {
    _ensureOpen();
    int count = 0;
    await for (final String _ in keys()) {
      count++;
    }
    return DatabaseInfo(
      path: _path,
      schemaVersion: _header.schemaVersion,
      syncMode: _syncMode.name,
      encryptionType: _encryption.type.name,
      entryCount: count,
      sizeBytes: _storage.stats.sstableSizeBytes,
      indexCount: _indexes.listIndexes().length,
    );
  }

  /// Aggregated live statistics for cache, storage and transactions.
  Map<String, dynamic> statistics() {
    _ensureOpen();
    final CacheStatistics cache = _cache.stats;
    final StorageStats storage = _storage.stats;
    final TransactionStats transactions = _transactions.stats;
    return <String, dynamic>{
      'database': <String, dynamic>{
        'path': _path,
        'schemaVersion': _header.schemaVersion,
        'syncMode': _syncMode.name,
        'encryption': _encryption.type.name,
      },
      'cache': <String, dynamic>{
        'entries': cache.entryCount,
        'memoryBytes': cache.memoryBytes,
        'hits': cache.hits,
        'misses': cache.misses,
        'evictions': cache.evictions,
        'expirations': cache.expirations,
        'hitRatio': cache.hitRatio,
      },
      'storage': <String, dynamic>{
        'memtableEntries': storage.memtableEntries,
        'memtableSizeBytes': storage.memtableSizeBytes,
        'sstableCount': storage.sstableCount,
        'sstableSizeBytes': storage.sstableSizeBytes,
        'levelTableCounts': storage.levelTableCounts,
        'lastSequenceNumber': storage.lastSequenceNumber,
      },
      'transactions': <String, dynamic>{
        'active': transactions.activeTransactions,
        'committed': transactions.committedTransactions,
        'aborted': transactions.abortedTransactions,
      },
    };
  }

  // -- 1.x diagnostics shims ----------------------------------------------

  /// The ReaxDB 1.x name for [info].
  ///
  /// Returns the real 2.0 [DatabaseInfo]. The 1.x version of this method
  /// reported a hardcoded path and `DateTime.now()` for both `createdAt` and
  /// `lastAccessed`; those fields no longer exist rather than being invented.
  @Deprecated('Use info(). Removed in 3.0.')
  Future<DatabaseInfo> getDatabaseInfo() => info();

  /// The ReaxDB 1.x name for [statistics].
  @Deprecated('Use statistics(). Removed in 3.0.')
  Future<Map<String, dynamic>> getStatistics() async => statistics();

  /// The ReaxDB 1.x name for [encryptionInfo].
  @Deprecated('Use encryptionInfo. Removed in 3.0.')
  Map<String, dynamic> getEncryptionInfo() => encryptionInfo;

  /// Performance counters, in the shape 1.x used.
  ///
  /// Every number here is measured. The 1.x version returned an
  /// `optimization` block of hardcoded `true` values describing nothing, and
  /// hit ratios that were NaN before the first read; that block is gone and
  /// the ratios come from the live cache statistics.
  @Deprecated(
    'Use statistics(), cacheStats, storageStats or transactionStats. '
    'Removed in 3.0.',
  )
  Map<String, dynamic> getPerformanceStats() {
    _ensureOpen();
    final CacheStatistics cache = _cache.stats;
    final StorageStats storage = _storage.stats;
    final TransactionStats transactions = _transactions.stats;
    return <String, dynamic>{
      'cache': <String, dynamic>{
        'hits': cache.hits,
        'misses': cache.misses,
        'hitRatio': cache.hitRatio,
        'entries': cache.entryCount,
        'evictions': cache.evictions,
      },
      'storage': <String, dynamic>{
        'sstableCount': storage.sstableCount,
        'sstableSizeBytes': storage.sstableSizeBytes,
        'memtableEntries': storage.memtableEntries,
        'lastSequenceNumber': storage.lastSequenceNumber,
      },
      'transactions': <String, dynamic>{
        'committed': transactions.committedTransactions,
        'aborted': transactions.abortedTransactions,
        'active': transactions.activeTransactions,
      },
    };
  }

  /// The ReaxDB 1.x stream of every change event.
  @Deprecated("Use watch('*') or changes. Removed in 3.0.")
  Stream<DatabaseChangeEvent> get changeStream => watch('*');

  /// The ReaxDB 1.x name for [watch].
  @Deprecated('Use watch(pattern). Removed in 3.0.')
  Stream<DatabaseChangeEvent> stream(String keyPattern) => watch(keyPattern);

  /// The ReaxDB 1.x name for [watch], as a [ReactiveStream].
  @Deprecated('Use watch(pattern). Removed in 3.0.')
  ReactiveStream watchPattern(String pattern) => ReactiveStream(watch(pattern));

  // -- backup and restore -------------------------------------------------

  /// Magic header of a ReaxDB export archive: "RXDB".
  static const int archiveMagic = 0x52584442;

  /// Format version of the export archive.
  static const int archiveVersion = 1;

  /// Writes a consistent snapshot of this database to [archivePath].
  ///
  /// The archive stores DECRYPTED record envelopes plus the index
  /// definitions, so a backup taken from an encrypted database can be
  /// restored into a database with different (or no) encryption. It carries
  /// a magic number, a format version and a SHA-256 digest of the body,
  /// verified on import.
  ///
  /// Writes are blocked for the duration of the snapshot scan, so the
  /// archive is a point-in-time image rather than a fuzzy copy.
  Future<int> exportTo(String archivePath) {
    _ensureOpen();
    return _track(
      () => _ioMutex.run(() async {
        final BytesBuilder body = BytesBuilder(copy: false);
        int entries = 0;
        await for (final KeyValue pair in _storage.scan(
          startKey: _userKeySpaceStart,
        )) {
          final Uint8List envelope = _toEnvelope(pair.value);
          Varint.write(body, pair.key.length);
          body.add(pair.key);
          Varint.write(body, envelope.length);
          body.add(envelope);
          entries++;
        }
        final Uint8List bodyBytes = body.takeBytes();

        final Uint8List metadata = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'schemaVersion': _header.schemaVersion,
              'entryCount': entries,
              'createdAtMs': DateTime.now().millisecondsSinceEpoch,
              'indexes': <Map<String, dynamic>>[
                for (final IndexDefinition d in _indexes.listIndexes())
                  <String, dynamic>{
                    'collection': d.collection,
                    'fields': d.fields,
                  },
              ],
            }),
          ),
        );

        final BytesBuilder out = BytesBuilder(copy: false);
        final ByteData head =
            ByteData(6)
              ..setUint32(0, archiveMagic, Endian.big)
              ..setUint16(4, archiveVersion, Endian.big);
        out.add(head.buffer.asUint8List());
        Varint.write(out, metadata.length);
        out.add(metadata);
        Varint.write(out, bodyBytes.length);
        out.add(bodyBytes);
        out.add(
          Uint8List.fromList(
            sha256.convert(<int>[...metadata, ...bodyBytes]).bytes,
          ),
        );

        final File file = File(archivePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(out.takeBytes(), flush: true);
        await _logger.info('Exported $entries entries to $archivePath');
        return entries;
      }),
    );
  }

  /// Restores the archive at [archivePath] into a database at [path].
  ///
  /// The target directory must be empty or non-existent unless [overwrite]
  /// is set, in which case existing contents are deleted first. The archive's
  /// checksum is verified before anything is written; a mismatch throws
  /// [CorruptionException]. Index definitions recorded in the archive are
  /// recreated and backfilled. Returns the restored database, open.
  static Future<ReaxDB> importFrom({
    required String archivePath,
    required String path,
    EncryptionConfig encryption = const EncryptionConfig.none(),
    SyncMode syncMode = SyncMode.full,
    bool overwrite = false,
  }) async {
    final File file = File(archivePath);
    if (!await file.exists()) {
      throw CorruptionException(
        'Archive not found: $archivePath',
        path: archivePath,
      );
    }
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.length < 6 + 32) {
      throw CorruptionException(
        'Archive is too small to be a ReaxDB export',
        path: archivePath,
      );
    }
    final ByteData head = ByteData.sublistView(bytes, 0, 6);
    if (head.getUint32(0, Endian.big) != archiveMagic) {
      throw CorruptionException(
        'Not a ReaxDB export archive (bad magic number)',
        path: archivePath,
        offset: 0,
      );
    }
    final int version = head.getUint16(4, Endian.big);
    if (version != archiveVersion) {
      throw CorruptionException(
        'Unsupported archive format version $version '
        '(supported: $archiveVersion)',
        path: archivePath,
        offset: 4,
      );
    }

    int cursor = 6;
    final (int metaLength, int metaRead) = Varint.read(bytes, cursor);
    cursor += metaRead;
    final Uint8List metadata = Uint8List.sublistView(
      bytes,
      cursor,
      cursor + metaLength,
    );
    cursor += metaLength;
    final (int bodyLength, int bodyRead) = Varint.read(bytes, cursor);
    cursor += bodyRead;
    final Uint8List body = Uint8List.sublistView(
      bytes,
      cursor,
      cursor + bodyLength,
    );
    cursor += bodyLength;
    if (bytes.length - cursor != 32) {
      throw CorruptionException(
        'Archive trailer is malformed',
        path: archivePath,
        offset: cursor,
      );
    }
    final Uint8List expected = Uint8List.sublistView(bytes, cursor);
    final List<int> actual = sha256.convert(<int>[...metadata, ...body]).bytes;
    for (int i = 0; i < 32; i++) {
      if (actual[i] != expected[i]) {
        throw CorruptionException(
          'Archive checksum mismatch: the file is damaged or truncated',
          path: archivePath,
          offset: cursor,
        );
      }
    }

    final Map<String, dynamic> meta =
        jsonDecode(utf8.decode(metadata)) as Map<String, dynamic>;

    final Directory directory = Directory(path);
    if (await directory.exists()) {
      final bool empty = await directory.list().isEmpty;
      if (!empty) {
        if (!overwrite) {
          throw DatabaseLockedException(
            'Target directory "$path" is not empty. Pass overwrite: true to '
            'replace its contents.',
            path: path,
          );
        }
        await directory.delete(recursive: true);
      }
    }

    final ReaxDB db = await ReaxDB.open(
      path: path,
      encryption: encryption,
      syncMode: syncMode,
      schemaVersion: (meta['schemaVersion'] as int?) ?? 1,
    );
    try {
      int offset = 0;
      Map<String, Object?> batch = <String, Object?>{};
      final List<DateTime?> expiries = <DateTime?>[];
      final List<String> batchKeys = <String>[];
      Future<void> flushBatch() async {
        for (int i = 0; i < batchKeys.length; i++) {
          await db.put(
            batchKeys[i],
            batch[batchKeys[i]],
            expiresAt: expiries[i],
          );
        }
        batch = <String, Object?>{};
        batchKeys.clear();
        expiries.clear();
      }

      while (offset < body.length) {
        final (int keyLength, int keyRead) = Varint.read(body, offset);
        offset += keyRead;
        final String key = utf8.decode(
          Uint8List.sublistView(body, offset, offset + keyLength),
        );
        offset += keyLength;
        final (int valueLength, int valueRead) = Varint.read(body, offset);
        offset += valueRead;
        final StoredRecord record = RecordEnvelope.decode(
          Uint8List.sublistView(body, offset, offset + valueLength),
        );
        offset += valueLength;
        batch[key] = record.value;
        batchKeys.add(key);
        expiries.add(record.expiresAt);
        if (batchKeys.length >= 500) await flushBatch();
      }
      await flushBatch();

      for (final Object? entry
          in (meta['indexes'] as List<dynamic>? ?? const [])) {
        final Map<String, dynamic> definition = entry as Map<String, dynamic>;
        await db.createIndex(
          definition['collection'] as String,
          (definition['fields'] as List<dynamic>).cast<String>(),
        );
      }
      return db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  // -- lifecycle ----------------------------------------------------------

  /// Closes the database.
  ///
  /// Drains work already accepted, flushes and closes the storage engine and
  /// its WAL, closes the transaction manager, index manager, cache, change
  /// stream hub and logger, releases the on-disk lock, and unregisters the
  /// instance so the path can be opened again. Idempotent.
  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    while (_inFlight.isNotEmpty) {
      await Future.wait<void>(_inFlight.toList());
    }
    await _ioMutex.run(() async {
      await _transactions.close();
      await _indexes.close();
      await _storage.close();
      _cache.clear();
      await _hub.close();
    });
    _instances.remove(_path);
    await _releaseLock(_lockFile);
    await _logger.info('Database closed');
    await _logger.close();
    _closed = true;
    _closing = false;
  }

  /// Closes every database open in this isolate. Intended for tests.
  static Future<void> closeAll() async {
    for (final ReaxDB db in _instances.values.toList()) {
      await db.close();
    }
  }

  // -- locking ------------------------------------------------------------

  /// Acquires the on-disk lock for [canonical].
  ///
  /// The lock is an OS advisory lock held on `<path>/LOCK` for the lifetime
  /// of the instance. Because the operating system releases advisory locks
  /// when a process dies, a crashed process never leaves a stale lock behind:
  /// the file may remain on disk, but it is not locked and the next open
  /// succeeds. There is therefore no stale-lock timeout to tune and no
  /// "force unlock" switch.
  static Future<RandomAccessFile> _acquireLock(String canonical) async {
    final File file = File(p.join(canonical, lockFileName));
    final RandomAccessFile handle = await file.open(mode: FileMode.write);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await handle.close();
      throw DatabaseLockedException(
        'Database at "$canonical" is locked by another process',
        path: canonical,
        cause: error,
      );
    }
    try {
      await handle.writeString('\$pid\n${DateTime.now().toIso8601String()}\n');
    } catch (_) {
      // The lock itself is what matters; the contents are informational.
    }
    return handle;
  }

  static Future<void> _releaseLock(RandomAccessFile handle) async {
    try {
      await handle.unlock();
    } catch (_) {
      // Already released, for example because the file was removed.
    }
    try {
      await handle.close();
    } catch (_) {
      // Nothing further to do while closing.
    }
  }

  static String _canonicalize(String path) => p.canonicalize(path);
}

/// A transaction handle with typed values.
///
/// Reads observe the transaction's own pending writes; writes are buffered
/// and applied atomically at commit.
final class ReaxTransaction {
  ReaxTransaction._(this._db, this._tx);

  final ReaxDB _db;
  final Transaction _tx;

  /// Identifier of the underlying transaction.
  int get id => _tx.id;

  /// Isolation level this transaction runs under.
  IsolationLevel get isolationLevel => _tx.isolationLevel;

  /// Reads [key] within the transaction, or null when absent or expired.
  Future<T?> get<T>(String key) async {
    final Uint8List? stored = await _tx.get(key);
    if (stored == null) return null;
    final StoredRecord record = RecordEnvelope.decode(_db._toEnvelope(stored));
    if (record.isExpiredAt(DateTime.now())) return null;
    return ReaxDB._cast<T>(key, record.value);
  }

  /// Buffers a write of [key] = [value] to apply at commit.
  Future<void> put(
    String key,
    Object? value, {
    Duration? ttl,
    DateTime? expiresAt,
  }) {
    ReaxDB.encodeKey(key);
    return _tx.put(
      key,
      _db._toStored(
        RecordEnvelope.encode(
          value,
          expiresAt: ReaxDB._resolveExpiry(ttl, expiresAt),
        ),
      ),
    );
  }

  /// Buffers a deletion of [key] to apply at commit.
  Future<void> delete(String key) {
    ReaxDB.encodeKey(key);
    return _tx.delete(key);
  }
}

/// One buffered mutation flowing through the write pipeline.
final class _Mutation {
  _Mutation.put(this.key, this.value, this.expiresAt)
    : envelope = RecordEnvelope.encode(value, expiresAt: expiresAt),
      isDelete = false;

  _Mutation.delete(this.key)
    : value = null,
      envelope = null,
      expiresAt = null,
      isDelete = true;

  final String key;
  final Object? value;
  final Uint8List? envelope;
  final DateTime? expiresAt;
  final bool isDelete;
}

/// The `collection:id` decomposition of a document key.
final class _DocumentAddress {
  const _DocumentAddress(this.collection, this.id);

  final String collection;
  final String id;

  static _DocumentAddress? parse(String key) {
    final int separator = key.indexOf(':');
    if (separator <= 0 || separator == key.length - 1) return null;
    return _DocumentAddress(
      key.substring(0, separator),
      key.substring(separator + 1),
    );
  }
}

/// [DocumentStore] implemented over the facade, so query-driven updates and
/// deletes go through the same write pipeline as any other mutation.
final class _FacadeDocumentStore implements DocumentStore {
  const _FacadeDocumentStore(this._db);

  final ReaxDB _db;

  @override
  Stream<DocumentRecord> scanDocuments(String collection) async* {
    await for (final ReaxEntry<Object?> entry in _db.scanPrefix<Object?>(
      '$collection:',
    )) {
      final Object? value = entry.value;
      if (value is Map<String, dynamic>) {
        yield DocumentRecord(entry.key.substring(collection.length + 1), value);
      }
    }
  }

  @override
  Stream<String> scanDocumentIds(String collection) async* {
    await for (final DocumentRecord record in scanDocuments(collection)) {
      yield record.id;
    }
  }

  @override
  Future<Map<String, dynamic>?> getDocument(String collection, String id) =>
      _db.get<Map<String, dynamic>>('$collection:$id');

  @override
  Future<void> putDocument(
    String collection,
    String id,
    Map<String, dynamic> document,
  ) => _db.put('$collection:$id', document);

  @override
  Future<void> deleteDocument(String collection, String id) =>
      _db.delete('$collection:$id');
}

/// The persisted database header.
///
/// Holds the schema version and, for passphrase-based encryption, the random
/// PBKDF2 salt and iteration count. Stored as CRC32-checked JSON in
/// `reaxdb.meta`, written atomically through a temporary file and rename.
final class _DatabaseHeader {
  const _DatabaseHeader({
    required this.schemaVersion,
    required this.encryptionType,
    required this.kdfSalt,
    required this.kdfIterations,
    required this.createdAtMs,
  });

  /// Header format version.
  static const int formatVersion = 1;

  final int schemaVersion;
  final String encryptionType;
  final Uint8List? kdfSalt;
  final int? kdfIterations;
  final int createdAtMs;

  _DatabaseHeader withSchemaVersion(int version) => _DatabaseHeader(
    schemaVersion: version,
    encryptionType: encryptionType,
    kdfSalt: kdfSalt,
    kdfIterations: kdfIterations,
    createdAtMs: createdAtMs,
  );

  static File _file(String directory) =>
      File(p.join(directory, ReaxDB.headerFileName));

  /// Loads the header for [directory], creating it on first open.
  ///
  /// Validates that [encryption] matches what the database was created with
  /// and reuses the persisted KDF salt so the same passphrase derives the
  /// same key on every open.
  static Future<_DatabaseHeader> load(
    String directory,
    EncryptionConfig encryption,
    int requestedSchemaVersion,
  ) async {
    final File file = _file(directory);
    if (!await file.exists()) {
      final _DatabaseHeader header = _DatabaseHeader(
        schemaVersion: requestedSchemaVersion,
        encryptionType: encryption.type.name,
        kdfSalt:
            encryption is Aes256PassphraseConfig
                ? KeyDerivation.generateSalt()
                : null,
        kdfIterations:
            encryption is Aes256PassphraseConfig ? encryption.iterations : null,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await header.save(directory);
      return header;
    }

    final Uint8List raw = await file.readAsBytes();
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (error) {
      throw CorruptionException(
        'Database header is not readable JSON',
        path: file.path,
        cause: error,
      );
    }
    final String payload = envelope['payload'] as String? ?? '';
    final int checksum = envelope['crc32'] as int? ?? -1;
    if (Crc32.compute(Uint8List.fromList(utf8.encode(payload))) != checksum) {
      throw CorruptionException(
        'Database header checksum mismatch',
        path: file.path,
      );
    }
    final Map<String, dynamic> data =
        jsonDecode(payload) as Map<String, dynamic>;
    final int headerVersion = data['formatVersion'] as int? ?? 0;
    if (headerVersion != formatVersion) {
      throw CorruptionException(
        'Unsupported database header version $headerVersion '
        '(supported: $formatVersion)',
        path: file.path,
      );
    }

    final String storedType = data['encryptionType'] as String;
    if (storedType != encryption.type.name) {
      throw EncryptionException(
        'Database at "$directory" was created with encryption "$storedType" '
        'but was opened with "${encryption.type.name}". Reopen it with the '
        'original configuration, or export and import the data.',
      );
    }

    final String? saltBase64 = data['kdfSalt'] as String?;
    final int? iterations = data['kdfIterations'] as int?;
    if (encryption is Aes256PassphraseConfig) {
      if (saltBase64 == null) {
        throw const EncryptionException(
          'Database header has no KDF salt but a passphrase configuration was '
          'supplied. The database was created with a raw-key configuration.',
        );
      }
      if (iterations != encryption.iterations) {
        throw EncryptionException(
          'Database was created with $iterations PBKDF2 iterations but '
          '${encryption.iterations} were requested. Use the original '
          'iteration count, or export and import the data.',
        );
      }
    }

    return _DatabaseHeader(
      schemaVersion: data['schemaVersion'] as int,
      encryptionType: storedType,
      kdfSalt: saltBase64 == null ? null : base64Decode(saltBase64),
      kdfIterations: iterations,
      createdAtMs: data['createdAtMs'] as int? ?? 0,
    );
  }

  /// Writes this header into [directory] atomically.
  Future<void> save(String directory) async {
    final String payload = jsonEncode(<String, dynamic>{
      'formatVersion': formatVersion,
      'schemaVersion': schemaVersion,
      'encryptionType': encryptionType,
      if (kdfSalt != null) 'kdfSalt': base64Encode(kdfSalt!),
      if (kdfIterations != null) 'kdfIterations': kdfIterations,
      'createdAtMs': createdAtMs,
    });
    final String document = jsonEncode(<String, dynamic>{
      'payload': payload,
      'crc32': Crc32.compute(Uint8List.fromList(utf8.encode(payload))),
    });
    final File target = _file(directory);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(document, flush: true);
    await temporary.rename(target.path);
  }
}

/// The ReaxDB 1.x database configuration object.
///
/// Kept so 1.x code compiles. [ReaxDB.open] maps it onto the 2.0 options:
///
/// | 1.x field | 2.0 equivalent |
/// |---|---|
/// | `memtableSizeMB` | `memtableSizeBytes` (times 1024 * 1024) |
/// | `syncWrites` | `syncMode: SyncMode.full` / `SyncMode.none` |
/// | `l1CacheSize` + `l2CacheSize` + `l3CacheSize` | `cacheMaxEntries` (their sum: 2.0 has one cache, not three) |
/// | `encryptionType` + `encryptionKey` | `encryption: EncryptionConfig...` |
///
/// The remaining fields are accepted and IGNORED, because they never
/// controlled anything in 1.x either: `pageSize`, `compressionEnabled`,
/// `maxImmutableMemtables`, `cacheSize` and `enableCache`.
@Deprecated(
  'Use the named parameters of ReaxDB.open (syncMode, memtableSizeBytes, '
  'cacheMaxEntries, cacheMaxMemoryBytes, encryption). Removed in 3.0.',
)
final class DatabaseConfig {
  /// Creates a 1.x-shaped configuration.
  const DatabaseConfig({
    required this.memtableSizeMB,
    required this.pageSize,
    required this.l1CacheSize,
    required this.l2CacheSize,
    required this.l3CacheSize,
    required this.compressionEnabled,
    required this.syncWrites,
    required this.maxImmutableMemtables,
    required this.cacheSize,
    required this.enableCache,
    this.encryptionType = EncryptionType.none,
  });

  /// The 1.x default configuration.
  factory DatabaseConfig.defaultConfig() => const DatabaseConfig(
    memtableSizeMB: 4,
    pageSize: 4096,
    l1CacheSize: 1000,
    l2CacheSize: 10000,
    l3CacheSize: 100,
    compressionEnabled: true,
    syncWrites: true,
    maxImmutableMemtables: 4,
    cacheSize: 50,
    enableCache: true,
  );

  /// The 1.x XOR configuration. XOR is obfuscation, not encryption.
  factory DatabaseConfig.withXorEncryption() => const DatabaseConfig(
    memtableSizeMB: 4,
    pageSize: 4096,
    l1CacheSize: 1000,
    l2CacheSize: 10000,
    l3CacheSize: 100,
    compressionEnabled: true,
    syncWrites: true,
    maxImmutableMemtables: 4,
    cacheSize: 50,
    enableCache: true,
    encryptionType: EncryptionType.obfuscation,
  );

  /// The 1.x AES-256 configuration.
  factory DatabaseConfig.withAes256Encryption() => const DatabaseConfig(
    memtableSizeMB: 4,
    pageSize: 4096,
    l1CacheSize: 1000,
    l2CacheSize: 10000,
    l3CacheSize: 100,
    compressionEnabled: true,
    syncWrites: true,
    maxImmutableMemtables: 4,
    cacheSize: 50,
    enableCache: true,
    encryptionType: EncryptionType.aes256,
  );

  /// Write buffer size in megabytes. Maps to `memtableSizeBytes`.
  final int memtableSizeMB;

  /// Ignored: 2.0 has no page-oriented store.
  final int pageSize;

  /// First cache tier size. Summed into `cacheMaxEntries`.
  final int l1CacheSize;

  /// Second cache tier size. Summed into `cacheMaxEntries`.
  final int l2CacheSize;

  /// Third cache tier size. Summed into `cacheMaxEntries`.
  final int l3CacheSize;

  /// Ignored: 1.x never compressed anything.
  final bool compressionEnabled;

  /// Whether writes are fsynced. Maps to `syncMode`.
  final bool syncWrites;

  /// Ignored: the 2.0 engine manages its own flush pipeline.
  final int maxImmutableMemtables;

  /// Ignored.
  final int cacheSize;

  /// Ignored: the cache is always on and bounded by `cacheMaxEntries`.
  final bool enableCache;

  /// Which cipher to apply. Combined with `encryptionKey` in `ReaxDB.open`.
  final EncryptionType encryptionType;
}

/// The subset of a deprecated [DatabaseConfig] that still means something.
final class _TuningOverrides {
  const _TuningOverrides({
    this.syncMode,
    this.memtableSizeBytes,
    this.cacheMaxEntries,
  });

  // ignore: deprecated_member_use_from_same_package
  factory _TuningOverrides.from(DatabaseConfig? config) {
    if (config == null) return const _TuningOverrides();
    return _TuningOverrides(
      syncMode: config.syncWrites ? SyncMode.full : SyncMode.none,
      memtableSizeBytes: config.memtableSizeMB * 1024 * 1024,
      cacheMaxEntries:
          config.l1CacheSize + config.l2CacheSize + config.l3CacheSize,
    );
  }

  final SyncMode? syncMode;
  final int? memtableSizeBytes;
  final int? cacheMaxEntries;
}

/// Serializes async critical sections in FIFO order.
final class _Mutex {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] after everything already queued has finished.
  Future<T> run<T>(Future<T> Function() action) async {
    final Future<void> previous = _tail;
    final Completer<void> gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }
}
