/// Log levels for the ReaxDB logging system.
enum LogLevel {
  /// No logging.
  none(0),

  /// Error messages only.
  error(1),

  /// Error and warning messages.
  warning(2),

  /// Error, warning and info messages.
  info(3),

  /// All messages including debug.
  debug(4);

  /// Numeric severity threshold; higher values log more.
  final int value;

  const LogLevel(this.value);

  /// Whether a message of [messageLevel] should be logged when this level is
  /// the configured threshold.
  bool shouldLog(LogLevel messageLevel) {
    return messageLevel.value <= value;
  }

  /// Short uppercase label used in formatted output.
  String get label {
    switch (this) {
      case LogLevel.error:
        return 'ERROR';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.none:
        return '';
    }
  }
}
