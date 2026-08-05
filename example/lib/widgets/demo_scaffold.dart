import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

/// The page layout shared by every demo: a title, a short explanation, the
/// snippet the demo is built from, and the demo itself.
class DemoScaffold extends StatelessWidget {
  /// Creates a demo page.
  const DemoScaffold({
    super.key,
    required this.title,
    required this.description,
    required this.snippet,
    required this.child,
    this.actions = const <Widget>[],
    this.scrollable = true,
  });

  /// Page title, shown in the app bar.
  final String title;

  /// One or two sentences describing what the demo shows.
  final String description;

  /// The ReaxDB calls the demo is built from.
  final String snippet;

  /// The demo body.
  final Widget child;

  /// Extra app bar actions.
  final List<Widget> actions;

  /// Whether the page scrolls as a whole. Demos whose body is itself a list
  /// pass false and manage their own scrolling.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(description, style: Theme.of(context).textTheme.bodyMedium),
          // Pages whose body is a list keep the snippet collapsed, so the
          // list itself gets the screen.
          SnippetTile(code: snippet, initiallyExpanded: scrollable),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body:
          scrollable
              ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    header,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: child,
                    ),
                  ],
                ),
              )
              : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[header, Expanded(child: child)],
              ),
    );
  }
}

/// A [DemoScaffold] that opens a database before showing its body and closes
/// it when the page is popped.
///
/// Flutter disposes children before their parent, so [builder]'s subtree has
/// already cancelled its subscriptions by the time the database is closed.
class DatabaseDemoScaffold extends StatefulWidget {
  /// Creates a demo page backed by a database.
  const DatabaseDemoScaffold({
    super.key,
    required this.title,
    required this.description,
    required this.snippet,
    required this.open,
    required this.builder,
    this.scrollable = true,
  });

  /// Page title, shown in the app bar.
  final String title;

  /// One or two sentences describing what the demo shows.
  final String description;

  /// The ReaxDB calls the demo is built from.
  final String snippet;

  /// Opens the database this page uses.
  final Future<ReaxDB> Function() open;

  /// Builds the body once the database is open.
  final Widget Function(BuildContext context, ReaxDB db) builder;

  /// Whether the page scrolls as a whole.
  final bool scrollable;

  @override
  State<DatabaseDemoScaffold> createState() => _DatabaseDemoScaffoldState();
}

class _DatabaseDemoScaffoldState extends State<DatabaseDemoScaffold> {
  ReaxDB? _db;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _openDatabase();
  }

  Future<void> _openDatabase() async {
    try {
      final ReaxDB db = await widget.open();
      if (!mounted) {
        await db.close();
        return;
      }
      setState(() => _db = db);
    } catch (error) {
      // Typed exceptions are rendered by name; anything else is shown as is.
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    // Closing drains work already accepted, so it is not awaited here.
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ReaxDB? db = _db;
    final Object? error = _error;
    if (error != null) {
      return DemoScaffold(
        title: widget.title,
        description: widget.description,
        snippet: widget.snippet,
        child: ErrorCard(error: error),
      );
    }
    if (db == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return DemoScaffold(
      title: widget.title,
      description: widget.description,
      snippet: widget.snippet,
      scrollable: widget.scrollable,
      child: widget.builder(context, db),
    );
  }
}

/// The expandable header that holds a demo's code snippet.
class SnippetTile extends StatelessWidget {
  /// Creates a snippet tile.
  const SnippetTile({
    super.key,
    required this.code,
    this.initiallyExpanded = true,
  });

  /// The source to display.
  final String code;

  /// Whether the snippet starts open.
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          'The ReaxDB calls',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: <Widget>[CodeSnippet(code: code)],
      ),
    );
  }
}

/// A monospaced block showing the ReaxDB calls a demo uses.
class CodeSnippet extends StatelessWidget {
  /// Creates a code block.
  const CodeSnippet({super.key, required this.code});

  /// The source to display.
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF263238),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          code.trim(),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.45,
            color: Color(0xFFCFD8DC),
          ),
        ),
      ),
    );
  }
}

/// Shows a database error, including the typed exception name.
class ErrorCard extends StatelessWidget {
  /// Creates an error card for [error].
  const ErrorCard({super.key, required this.error});

  /// The error to describe.
  final Object error;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  error is ReaxDbException
                      ? error.runtimeType.toString()
                      : 'Error',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error is ReaxDbException
                  ? (error as ReaxDbException).message
                  : error.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
