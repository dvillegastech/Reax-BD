import 'dart:io';

import 'log_level.dart';
import 'log_output.dart';

/// Log output that appends formatted records to a file.
///
/// Requires `dart:io` and is therefore NOT part of the core
/// `package:reaxdb_dart/reaxdb_dart.dart` barrel (which must stay
/// web-compatible). Import it via
/// `package:reaxdb_dart/reaxdb_dart_io.dart`.
///
/// Ownership: the logger this output is attached to closes it in its own
/// `close()`. If you attach it to a per-database logger, the database's
/// `close()` closes the sink; never reuse an output after it was closed.
class FileLogOutput extends LogOutput {
  /// Opens (or creates) [filePath] for appending.
  FileLogOutput(this.filePath)
    : _sink = File(filePath).openWrite(mode: FileMode.append);

  /// The path of the log file.
  final String filePath;

  final IOSink _sink;
  bool _closed = false;

  @override
  Future<void> write(
    LogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  }) async {
    if (_closed) {
      return;
    }
    final String timestamp = DateTime.now().toIso8601String();
    final StringBuffer line = StringBuffer(
      '[$timestamp] ${level.label}: $message',
    );
    if (metadata != null && metadata.isNotEmpty) {
      line.write(' | metadata: $metadata');
    }
    _sink.writeln(line.toString());
    await _sink.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }
}
