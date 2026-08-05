/// Read-only support for databases written by ReaxDB 1.x.
///
/// ReaxDB 2.0 changed every on-disk format: the write-ahead log and the
/// SSTables gained a header, a format version and CRC32 checksums, values
/// gained a self-describing record envelope, and encrypted values gained a
/// versioned ciphertext envelope with a PBKDF2-derived key and a random IV.
/// A 1.x directory is therefore not readable by the 2.x engine and must be
/// migrated.
///
/// Everything in this library reads. Nothing here writes the 1.x format, and
/// the 1.x key derivation is never used to protect newly written data: a
/// migrated database is written through the ordinary 2.x public API and
/// re-encrypted with the [EncryptionConfig] the caller chooses.
///
/// ```dart
/// final LegacyDatabaseInfo? info = await LegacyMigration.detect(path);
/// if (info != null) {
///   final MigrationReport report = await LegacyMigration.migrate(
///     sourcePath: path,
///     targetPath: path,
///     legacyEncryptionKey: info.looksEncrypted ? oldKey : null,
///     encryption: EncryptionConfig.aes256FromPassphrase(passphrase: secret),
///   );
///   print('migrated ${report.entriesMigrated}, backup at ${report.backupPath}');
/// }
/// ```
library;

export 'legacy_encryption.dart' show LegacyDecryptor, LegacyEncryptionMode;
export 'legacy_migrator.dart'
    show LegacyDatabaseInfo, LegacyMigration, MigrationReport;
export 'legacy_sstable_reader.dart'
    show LegacySSTable, LegacySSTableReader, LegacySSTableRecord;
export 'legacy_value_codec.dart' show LegacyValueCodec;
export 'legacy_wal_reader.dart'
    show LegacyWalEntry, LegacyWalEntryType, LegacyWalReader, LegacyWalScan;
