import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/action_button.dart';
import '../widgets/console_widget.dart';
import '../widgets/demo_scaffold.dart';

/// Exporting a snapshot and restoring it, including into a database with
/// different encryption.
class BackupDemoScreen extends StatelessWidget {
  /// Creates the backup demo.
  const BackupDemoScreen({super.key});

  static const String _snippet = '''
final entries = await db.exportTo('\$documents/backup.rxdb');

final restored = await ReaxDB.importFrom(
  archivePath: '\$documents/backup.rxdb',
  path: '\$documents/restored',
  // The archive stores decrypted records, so the copy may use a different
  // cipher from the original.
  encryption: EncryptionConfig.aes256(key: keyBytes32),
  overwrite: true,
);
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Backup and restore',
      description:
          'exportTo blocks writes for the duration of the scan, so the '
          'archive is a point-in-time image rather than a fuzzy copy. It '
          'carries a magic number, a format version, the schema version, the '
          'index definitions and a SHA-256 digest that importFrom verifies '
          'before it writes anything.',
      snippet: _snippet,
      open: () => DatabaseService.open('backup_source'),
      builder: (BuildContext context, ReaxDB db) => _BackupBody(db: db),
    );
  }
}

class _BackupBody extends StatefulWidget {
  const _BackupBody({required this.db});

  final ReaxDB db;

  @override
  State<_BackupBody> createState() => _BackupBodyState();
}

class _BackupBodyState extends State<_BackupBody> {
  static const String _archiveName = 'demo-backup.rxdb';
  static const String _restoredName = 'backup_restored';

  final ConsoleController _console = ConsoleController();
  bool _busy = false;
  bool _hasArchive = false;

  @override
  void initState() {
    super.initState();
    _checkArchive();
  }

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  Future<void> _checkArchive() async {
    final bool exists =
        await File(await DatabaseService.filePath(_archiveName)).exists();
    if (!mounted) return;
    setState(() => _hasArchive = exists);
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on ReaxDbException catch (error) {
      _console.failure('${error.runtimeType}: ${error.message}');
    } finally {
      await _checkArchive();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seed() => _run(() async {
    await widget.db.createIndex('note', <String>['tag']);
    await widget.db.putBatch(<String, Object?>{
      for (int i = 0; i < 100; i++)
        'note:${i.toString().padLeft(3, '0')}': <String, dynamic>{
          'title': 'Note $i',
          'tag': <String>['work', 'home', 'travel'][i % 3],
          'body': 'Body of note $i.',
        },
    });
    final DatabaseInfo info = await widget.db.info();
    _console.success(
      'Source database: ${info.entryCount} entries, '
      '${info.indexCount} index.',
    );
  });

  Future<void> _export() => _run(() async {
    final String path = await DatabaseService.filePath(_archiveName);
    final int entries = await widget.db.exportTo(path);
    final int bytes = await File(path).length();
    _console.section('exportTo');
    _console.success('$entries entries written to $_archiveName ($bytes B).');
  });

  Future<void> _restore() => _run(() async {
    final String archive = await DatabaseService.filePath(_archiveName);
    final String target = await DatabaseService.pathFor(_restoredName);

    // A fresh 256-bit key, as a platform keystore would hand you.
    final Random random = Random.secure();
    final Uint8List key = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );

    _console.section('importFrom');
    final ReaxDB restored = await ReaxDB.importFrom(
      archivePath: archive,
      path: target,
      encryption: EncryptionConfig.aes256(key: key),
      overwrite: true,
    );
    try {
      final DatabaseInfo info = await restored.info();
      final Map<String, dynamic>? note = await restored
          .get<Map<String, dynamic>>('note:042');
      final List<Map<String, dynamic>> work = await restored.where(
        'note',
        'tag',
        'work',
      );
      _console.success(
        'Restored ${info.entryCount} entries with '
        '${info.encryptionType} encryption.',
      );
      _console.info('note:042 -> ${note?['title']}');
      _console.info(
        '${work.length} notes tagged "work" — the index definition travelled '
        'in the archive and was backfilled on import.',
      );
    } finally {
      await restored.close();
    }
  });

  Future<void> _restoreDamaged() => _run(() async {
    final String source = await DatabaseService.filePath(_archiveName);
    final String damagedPath = await DatabaseService.filePath(
      'damaged-$_archiveName',
    );
    final Uint8List bytes = await File(source).readAsBytes();
    // Flip one bit in the middle of the body.
    bytes[bytes.length ~/ 2] ^= 0x01;
    await File(damagedPath).writeAsBytes(bytes, flush: true);

    _console.section('importFrom with a damaged archive');
    try {
      final ReaxDB db = await ReaxDB.importFrom(
        archivePath: damagedPath,
        path: await DatabaseService.pathFor('backup_damaged'),
        overwrite: true,
      );
      await db.close();
      _console.failure('The damaged archive was accepted, which is a bug.');
    } on CorruptionException catch (error) {
      _console.success('Rejected before writing anything: ${error.message}');
    } finally {
      await File(damagedPath).delete();
      await DatabaseService.delete('backup_damaged');
    }
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ActionButton(
              label: 'Seed 100 notes',
              icon: Icons.note_add_outlined,
              onPressed: _busy ? null : _seed,
            ),
            ActionButton(
              label: 'Export',
              icon: Icons.upload_file_outlined,
              tonal: true,
              onPressed: _busy ? null : _export,
            ),
            ActionButton(
              label: 'Restore, encrypted',
              icon: Icons.lock_outline,
              tonal: true,
              onPressed: _busy || !_hasArchive ? null : _restore,
            ),
            ActionButton(
              label: 'Restore a damaged copy',
              icon: Icons.report_gmailerrorred_outlined,
              tonal: true,
              onPressed: _busy || !_hasArchive ? null : _restoreDamaged,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ConsoleWidget(controller: _console, height: 300),
      ],
    );
  }
}
