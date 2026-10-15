// A Flutter app that streams a chat reply from your own backend route.
//
// The route is a server endpoint such as the Shelf handler from
// package:gauss_meridian/shelf.dart. The app holds no project key.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gauss_meridian_flutter/gauss_meridian_flutter.dart';

void main() => runApp(const ChatApp());

/// The example application.
class ChatApp extends StatelessWidget {
  /// Creates the example application.
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: ChatReply())),
  );
}

/// Streams one reply and shows the text as it arrives.
class ChatReply extends StatefulWidget {
  /// Creates the reply widget.
  const ChatReply({super.key});

  @override
  State<ChatReply> createState() => _ChatReplyState();
}

class _ChatReplyState extends State<ChatReply> {
  final _client = MeridianBrowser(
    route: 'https://app.example/api/meridian/chat',
  );
  StreamSubscription<ChatChunk>? _subscription;
  String _text = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final opened = await _client.chat.stream(
      ChatParams(messages: [ChatMessage.user('Hello')]),
    );
    if (!mounted) return;
    switch (opened) {
      case Ok<ChatStream>(data: final stream):
        // Keep the accumulated text in state; each chunk carries one delta.
        _subscription = stream.listen(
          (chunk) => setState(() => _text += chunk.delta),
        );
        final end = await stream.done;
        if (end != null && end.code != 'aborted' && mounted) {
          setState(() => _error = end.message);
        }
      case Err<ChatStream>(:final error):
        setState(() => _error = error.message);
    }
  }

  @override
  void dispose() {
    // Cancelling the subscription aborts the upstream request.
    _subscription?.cancel();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(_error == null ? _text : 'Error: $_error');
}
