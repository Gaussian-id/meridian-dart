@TestOn('browser')
library;

import 'dart:async';

import 'package:gauss_meridian/browser.dart';
import 'package:gauss_meridian/gauss_meridian.dart' as server;
import 'package:test/test.dart';

void main() {
  Future<Uri> route() async {
    final channel = spawnHybridUri(Uri(path: '/test/web/sse_server.dart'));
    final port = await channel.stream.first as int;
    return Uri.parse('http://127.0.0.1:$port/chat');
  }

  ChatParams prompt() => ChatParams(messages: [ChatMessage.user('Halo')]);

  test('browser receives the first SSE chunk before the last', () async {
    final client = MeridianBrowser(route: (await route()).toString());
    addTearDown(client.close);
    final opened = await client.chat.stream(prompt());
    expect(opened, isA<Ok<ChatStream>>());
    final stream = (opened as Ok<ChatStream>).data;
    final chunks = <String>[];
    final arrivals = <DateTime>[];

    await for (final chunk in stream) {
      chunks.add(chunk.delta);
      arrivals.add(DateTime.now());
    }

    expect(chunks, ['first', 'last']);
    expect(
      arrivals.last.difference(arrivals.first).inMilliseconds,
      greaterThanOrEqualTo(250),
    );
    expect(await stream.done, isNull);
  });

  test('cancel stops a browser stream before the final chunk', () async {
    final client = MeridianBrowser(route: (await route()).toString());
    addTearDown(client.close);
    final opened = await client.chat.stream(prompt());
    expect(opened, isA<Ok<ChatStream>>());
    final stream = (opened as Ok<ChatStream>).data;
    final first = Completer<void>();
    final received = <String>[];
    final subscription = stream.listen((chunk) {
      received.add(chunk.delta);
      if (!first.isCompleted) first.complete();
    });

    await first.future;
    await stream.cancel();
    await subscription.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(received, ['first']);
    expect((await stream.done)?.code, 'aborted');
  });

  test('server client returns the browser runtime refusal', () async {
    final client = server.Meridian(
      url: (await route()).toString(),
      key: 'not-a-real-key',
    );
    addTearDown(client.close);

    final result = await client.chat.create(prompt());

    expect(result, isA<server.Err<server.ChatCompletion>>());
    final error = (result as server.Err<server.ChatCompletion>).error;
    expect(error.code, 'invalid_request');
    expect(error.type, 'client_error');
    expect(error.message, contains('MeridianBrowser'));
  });
}
