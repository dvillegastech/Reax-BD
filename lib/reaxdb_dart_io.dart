/// `dart:io`-dependent additions to ReaxDB.
///
/// The main `package:reaxdb_dart/reaxdb_dart.dart` barrel is free of
/// `dart:io` so it can compile for the web. Import this entry point in VM /
/// Flutter (non-web) code that needs file-based logging.
library;

export 'src/core/logging/file_log_output.dart';
