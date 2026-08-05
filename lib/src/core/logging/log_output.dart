import 'log_level.dart';

/// Destination for log records.
///
/// This file is platform-independent (no `dart:io`) so the core library can
/// be compiled for the web. The file-based output lives in
/// `file_log_output.dart`, exported through the `reaxdb_dart_io.dart` entry
/// point.
///
/// Outputs passed to a `ReaxLogger` are owned by that logger: its `close()`
/// closes them. Do not share one output instance between loggers unless you
/// manage its lifecycle yourself.
abstract class LogOutput {
  /// Writes a single log record.
  Future<void> write(
    LogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  });

  /// Releases any resources held by this output.
  Future<void> close() async {}
}

/// Log output that prints to the console via [print].
class ConsoleLogOutput extends LogOutput {
  /// Creates a console output.
  ///
  /// [useColors] enables ANSI color codes. It defaults to false because
  /// terminal capability cannot be detected without `dart:io`.
  ConsoleLogOutput({this.useColors = false});

  /// Whether ANSI color escape codes are emitted.
  final bool useColors;

  @override
  Future<void> write(
    LogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  }) async {
    final String timestamp = DateTime.now().toIso8601String();
    final String prefix = level.label;
    final String color = useColors ? _color(level) : '';
    final String reset = useColors ? '\x1B[0m' : '';
    final String line = '$color[$timestamp] $prefix: $message$reset';
    if (metadata != null && metadata.isNotEmpty) {
      print('$line $metadata');
    } else {
      print(line);
    }
  }

  String _color(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return '\x1B[31m';
      case LogLevel.warning:
        return '\x1B[33m';
      case LogLevel.info:
        return '\x1B[34m';
      case LogLevel.debug:
        return '\x1B[90m';
      case LogLevel.none:
        return '';
    }
  }
}

/// In-memory log output, primarily for tests.
class MemoryLogOutput extends LogOutput {
  /// All records written so far, in order.
  final List<LogEntry> logs = <LogEntry>[];

  @override
  Future<void> write(
    LogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  }) async {
    logs.add(
      LogEntry(
        level: level,
        message: message,
        metadata: metadata,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Discards all recorded entries.
  void clear() => logs.clear();
}

/// A single recorded log entry.
class LogEntry {
  /// Creates a log entry.
  LogEntry({
    required this.level,
    required this.message,
    this.metadata,
    required this.timestamp,
  });

  /// Severity of the entry.
  final LogLevel level;

  /// The log message.
  final String message;

  /// Structured metadata attached to the entry, if any.
  final Map<String, dynamic>? metadata;

  /// When the entry was written.
  final DateTime timestamp;

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] ${level.label}: $message'
      '${metadata == null || metadata!.isEmpty ? '' : ' $metadata'}';
}
