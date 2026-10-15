// Run on a server with MERIDIAN_URL and MERIDIAN_KEY set in the environment:
//
//   dart run example/main.dart
//
// The project key stays on the server; never ship it to a browser or an app.
import 'dart:io';

import 'package:gauss_meridian/gauss_meridian.dart';

Future<void> main() async {
  final client = Meridian();
  try {
    // A single reply. Every call returns Ok or Err; nothing is thrown.
    final result = await client.chat.create(
      ChatParams(messages: [ChatMessage.user('Say hello in one sentence.')]),
    );
    switch (result) {
      case Ok<ChatCompletion>(:final data):
        stdout.writeln(data.text);
      case Err<ChatCompletion>(:final error):
        stderr.writeln('${error.code}: ${error.message}');
        return;
    }

    // A streamed reply, printed as each delta arrives.
    final opened = await client.chat.stream(
      ChatParams(
        messages: [ChatMessage.user('Count from one to five.')],
        model: 'meridian/auto:low',
      ),
    );
    switch (opened) {
      case Err<ChatStream>(:final error):
        stderr.writeln('${error.code}: ${error.message}');
      case Ok<ChatStream>(data: final stream):
        await for (final chunk in stream) {
          stdout.write(chunk.delta);
        }
        stdout.writeln();
        final end = await stream.done;
        if (end != null) stderr.writeln('${end.code}: ${end.message}');
    }
  } finally {
    client.close();
  }
}
