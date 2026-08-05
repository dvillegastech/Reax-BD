/// Public value types describing database entries, events and statistics.
///
/// Every `toString()` here is REDACTED: keys are reduced to a non-reversible
/// fingerprint and values to a type/size description. These objects routinely
/// end up in log lines, exception messages and debugger output, and a
/// database entry is by definition user data.
library;

import '../../core/logging/redaction.dart';

/// A key/value pair read from the database.
///
/// [value] is already decoded to the requested type; [expiresAt] is the
/// absolute expiry instant of the entry, or null when it never expires.
final class ReaxEntry<T> {
  /// Creates an entry.
  const ReaxEntry({required this.key, required this.value, this.expiresAt});

  /// The entry key.
  final String key;

  /// The decoded value.
  final T value;

  /// When the entry expires, or null when it does not.
  final DateTime? expiresAt;

  @override
  bool operator ==(Object other) =>
      other is ReaxEntry<T> &&
      other.key == key &&
      other.value == value &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(key, value, expiresAt);

  /// Redacted description: never includes the key or value content.
  @override
  String toString() =>
      'ReaxEntry(${Redaction.key(key)}, ${Redaction.value(value)}'
      '${expiresAt == null ? '' : ', expiresAt: $expiresAt'})';
}

/// Point-in-time description of an open database.
final class DatabaseInfo {
  /// Creates a database description.
  const DatabaseInfo({
    required this.path,
    required this.schemaVersion,
    required this.syncMode,
    required this.encryptionType,
    required this.entryCount,
    required this.sizeBytes,
    required this.indexCount,
  });

  /// Absolute path of the database directory.
  final String path;

  /// Schema version currently recorded in the database header.
  final int schemaVersion;

  /// Name of the effective default sync mode.
  final String syncMode;

  /// Name of the effective encryption algorithm.
  final String encryptionType;

  /// Number of live user entries (index postings excluded).
  final int entryCount;

  /// Total bytes of SSTable data on disk.
  final int sizeBytes;

  /// Number of secondary indexes defined.
  final int indexCount;

  @override
  String toString() =>
      'DatabaseInfo(path: $path, schemaVersion: $schemaVersion, '
      'entries: $entryCount, size: ${(sizeBytes / 1024).toStringAsFixed(1)}KB, '
      'sync: $syncMode, encryption: $encryptionType, indexes: $indexCount)';
}

/// The kind of change described by a [DatabaseChangeEvent].
enum ChangeType {
  /// A key was inserted or overwritten.
  put,

  /// A key was removed, either explicitly or because its TTL elapsed.
  delete,
}

/// A change applied to the database, delivered after its durability point.
///
/// Events are published only once the mutation is durable per the effective
/// sync mode, so an observer that sees an event can rely on the write having
/// been acknowledged.
final class DatabaseChangeEvent {
  /// Creates a change event.
  const DatabaseChangeEvent({
    required this.type,
    required this.key,
    required this.value,
    required this.timestamp,
  });

  /// Whether the key was written or removed.
  final ChangeType type;

  /// The key that changed.
  final String key;

  /// The new value for a [ChangeType.put], null for a delete.
  final Object? value;

  /// When the change was published.
  final DateTime timestamp;

  /// Redacted description: never includes the key or value content.
  @override
  String toString() =>
      'DatabaseChangeEvent(${type.name}, ${Redaction.key(key)}, '
      '${Redaction.value(value)}, at: ${timestamp.toIso8601String()})';
}
