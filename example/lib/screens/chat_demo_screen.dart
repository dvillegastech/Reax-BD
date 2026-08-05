import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import '../services/database_service.dart';
import '../widgets/demo_scaffold.dart';

/// An append-only message log rendered live from a change stream.
class ChatDemoScreen extends StatelessWidget {
  /// Creates the chat demo.
  const ChatDemoScreen({super.key});

  static const String _snippet = '''
// Load the tail of the log: the last 50 messages, then flip to chronological.
final recent = await db
    .scanPrefix<Map<String, dynamic>>('message:', reverse: true, limit: 50)
    .toList();

// From here on the stream is the source of truth: append, never reload.
_subscription = db.watchPrefix('message:').listen((event) {
  if (event.type == ChangeType.put) append(event.value);
});
''';

  @override
  Widget build(BuildContext context) {
    return DatabaseDemoScaffold(
      title: 'Chat',
      description:
          'The initial page comes from a reverse prefix scan; every message '
          'after that arrives on the change stream, which fires only once a '
          'write is durable. Nothing here polls the database.',
      snippet: _snippet,
      scrollable: false,
      open: () => DatabaseService.open('chat'),
      builder: (BuildContext context, ReaxDB db) => _ChatBody(db: db),
    );
  }
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({required this.db});

  final ReaxDB db;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  static const List<String> _replies = <String>[
    'Understood.',
    'Let me check and get back to you.',
    'That matches what I have here.',
    'Could you send the reference number?',
    'Thanks, noted.',
  ];

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  StreamSubscription<DatabaseChangeEvent>? _subscription;
  Timer? _replyTimer;
  List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];
  String _sender = 'Ada';

  @override
  void initState() {
    super.initState();
    _subscription = widget.db.watchPrefix('message:').listen(_onChange);
    _loadTail();
  }

  @override
  void dispose() {
    _replyTimer?.cancel();
    _subscription?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadTail() async {
    final List<ReaxEntry<Map<String, dynamic>>> tail =
        await widget.db
            .scanPrefix<Map<String, dynamic>>(
              'message:',
              reverse: true,
              limit: 50,
            )
            .toList();
    if (!mounted) return;
    setState(
      () =>
          _messages =
              tail.reversed
                  .map((ReaxEntry<Map<String, dynamic>> e) => e.value)
                  .toList(),
    );
    _scrollToEnd();
  }

  void _onChange(DatabaseChangeEvent event) {
    if (!mounted) return;
    if (event.type == ChangeType.delete) {
      setState(() => _messages = <Map<String, dynamic>>[]);
      return;
    }
    final Object? value = event.value;
    if (value is! Map<String, dynamic>) return;
    setState(() => _messages = <Map<String, dynamic>>[..._messages, value]);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _controller.clear();
    await _append(_sender, trimmed);
    if (_sender != 'Ada') return;
    _replyTimer?.cancel();
    _replyTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      _append('Support', _replies[trimmed.length % _replies.length]);
    });
  }

  Future<void> _append(String sender, String text) async {
    if (widget.db.isClosed) return;
    await widget.db.put(
      'message:${DateTime.now().microsecondsSinceEpoch}',
      <String, dynamic>{
        'sender': sender,
        'text': text,
        'sentAt': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<void> _clear() async {
    final List<String> keys = await widget.db.keys(prefix: 'message:').toList();
    await widget.db.deleteBatch(keys);
    if (mounted) setState(() => _messages = <Map<String, dynamic>>[]);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(value: 'Ada', label: Text('Ada')),
                    ButtonSegment<String>(
                      value: 'Support',
                      label: Text('Support'),
                    ),
                  ],
                  selected: <String>{_sender},
                  onSelectionChanged:
                      (Set<String> selection) =>
                          setState(() => _sender = selection.first),
                ),
              ),
              IconButton(
                onPressed: _messages.isEmpty ? null : _clear,
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Delete the log',
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _messages.isEmpty
                  ? const Center(child: Text('No messages yet.'))
                  : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Map<String, dynamic> message = _messages[index];
                      final bool mine = message['sender'] == _sender;
                      return Align(
                        alignment:
                            mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.72,
                          ),
                          decoration: BoxDecoration(
                            color:
                                mine
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                message['sender'] as String? ?? '',
                                style: theme.textTheme.labelSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(message['text'] as String? ?? ''),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Type a message',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: _send,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: () => _send(_controller.text),
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
