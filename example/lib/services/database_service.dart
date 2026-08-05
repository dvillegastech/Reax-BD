import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

/// Resolves where the example keeps its databases and opens them.
///
/// Every demo screen owns its own database directory under a single example
/// root, so the demos never contend for the same on-disk lock and each screen
/// can close its database when it is disposed.
class DatabaseService {
  DatabaseService._();

  /// Name of the example root directory inside the application documents
  /// directory.
  static const String rootDirectoryName = 'reaxdb_example';

  /// Resolves the directory the example root lives in.
  ///
  /// Overridable so tests can point the example at a temporary directory
  /// instead of the platform's documents directory.
  static Future<Directory> Function() documentsDirectory =
      getApplicationDocumentsDirectory;

  /// Absolute path of the example root directory.
  static Future<String> rootPath() async {
    final Directory documents = await documentsDirectory();
    final Directory root = Directory(p.join(documents.path, rootDirectoryName));
    await root.create(recursive: true);
    return root.path;
  }

  /// Absolute path of the database directory named [name].
  static Future<String> pathFor(String name) async =>
      p.join(await rootPath(), name);

  /// Opens the database named [name] with the full [ReaxDB] API.
  ///
  /// ```dart
  /// final db = await ReaxDB.open(
  ///   path: '${documentsDirectory.path}/reaxdb_example/tasks',
  ///   syncMode: SyncMode.full,
  /// );
  /// ```
  static Future<ReaxDB> open(
    String name, {
    EncryptionConfig encryption = const EncryptionConfig.none(),
    SyncMode syncMode = SyncMode.full,
    int schemaVersion = 1,
    FutureOr<void> Function(int from, int to, ReaxDB db)? onUpgrade,
  }) async => ReaxDB.open(
    path: await pathFor(name),
    encryption: encryption,
    syncMode: syncMode,
    schemaVersion: schemaVersion,
    onUpgrade: onUpgrade,
    loggerName: name,
  );

  /// Opens the database named [name] with the small key/value API.
  ///
  /// ReaxDB 2.0 never derives a key from the database name: pass a real
  /// [EncryptionConfig] when the values need to be encrypted.
  static Future<SimpleReaxDB> openSimple(
    String name, {
    EncryptionConfig encryption = const EncryptionConfig.none(),
  }) async =>
      ReaxDB.simple(name, path: await pathFor(name), encryption: encryption);

  /// Deletes the database directory named [name].
  ///
  /// The database must be closed first; a scratch database used by a demo is
  /// removed this way so the demo starts from a known state.
  static Future<void> delete(String name) async {
    final Directory directory = Directory(await pathFor(name));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  /// Absolute path of a file inside the example root, used for backups.
  static Future<String> filePath(String relative) async =>
      p.join(await rootPath(), relative);
}
