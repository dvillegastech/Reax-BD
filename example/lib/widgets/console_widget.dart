import 'package:flutter/material.dart';

/// Severity of a console line. It only affects colouring.
enum LogTone {
  /// Neutral progress output.
  info,

  /// An operation completed as expected.
  success,

  /// Something worth noticing, but not a failure.
  warning,

  /// An operation failed.
  failure,
}

/// One line of console output.
@immutable
class ConsoleLine {
  /// Creates a console line stamped with [time].
  const ConsoleLine(this.text, this.tone, this.time);

  /// The text to display.
  final String text;

  /// How the line is coloured.
  final LogTone tone;

  /// When the line was appended.
  final DateTime time;
}

/// Collects the console output of one demo screen.
///
/// Screens create a controller in `initState` and dispose it in `dispose`,
/// exactly like a [TextEditingController].
class ConsoleController extends ValueNotifier<List<ConsoleLine>> {
  /// Creates an empty console.
  ConsoleController() : super(const <ConsoleLine>[]);

  void _add(String text, LogTone tone) {
    value = <ConsoleLine>[...value, ConsoleLine(text, tone, DateTime.now())];
  }

  /// Appends neutral output.
  void info(String text) => _add(text, LogTone.info);

  /// Appends output describing a successful operation.
  void success(String text) => _add(text, LogTone.success);

  /// Appends output describing something noteworthy.
  void warning(String text) => _add(text, LogTone.warning);

  /// Appends output describing a failure.
  void failure(String text) => _add(text, LogTone.failure);

  /// Appends a section title, preceded by a blank line.
  void section(String title) {
    if (value.isNotEmpty) _add('', LogTone.info);
    _add(title, LogTone.info);
  }

  /// Removes every line.
  void clear() => value = const <ConsoleLine>[];
}

/// A terminal-style view of the output collected by a [ConsoleController].
///
/// New lines scroll into view, so the newest output is always the visible
/// output.
class ConsoleWidget extends StatefulWidget {
  /// Creates a console view.
  const ConsoleWidget({super.key, required this.controller, this.height = 280});

  /// The controller holding the lines to display.
  final ConsoleController controller;

  /// Fixed height of the console body.
  final double height;

  @override
  State<ConsoleWidget> createState() => _ConsoleWidgetState();
}

class _ConsoleWidgetState extends State<ConsoleWidget> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  static const Map<LogTone, Color> _colors = <LogTone, Color>{
    LogTone.info: Color(0xFFB0BEC5),
    LogTone.success: Color(0xFF81C784),
    LogTone.warning: Color(0xFFFFB74D),
    LogTone.failure: Color(0xFFE57373),
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ConsoleLine>>(
      valueListenable: widget.controller,
      builder: (BuildContext context, List<ConsoleLine> lines, _) {
        if (lines.isNotEmpty) _scrollToEnd();
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                color: const Color(0xFF37474F),
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.terminal,
                      size: 18,
                      color: Color(0xFF81C784),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Output',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${lines.length} lines',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    IconButton(
                      onPressed: widget.controller.clear,
                      icon: const Icon(Icons.clear_all, color: Colors.white70),
                      tooltip: 'Clear output',
                    ),
                  ],
                ),
              ),
              Container(
                height: widget.height,
                width: double.infinity,
                color: const Color(0xFF263238),
                child:
                    lines.isEmpty
                        ? const Center(
                          child: Text(
                            'Run an action to see output here.',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                        : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: lines.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ConsoleLine line = lines[index];
                            final String stamp = line.time
                                .toIso8601String()
                                .substring(11, 19);
                            return Text(
                              line.text.isEmpty ? '' : '$stamp  ${line.text}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                                color: _colors[line.tone],
                              ),
                            );
                          },
                        ),
              ),
            ],
          ),
        );
      },
    );
  }
}
