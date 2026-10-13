import 'dart:convert';

import 'package:meridian/browser.dart';
import 'package:test/test.dart' hide completion;

import 'support/fake_engine.dart';

void main() {
  late FakeEngine engine;
  late MeridianBrowser client;
  const route = 'https://example.com/api/meridian/chat';

  setUp(() {
    engine = FakeEngine();
    client =
        MeridianBrowser(route: route, httpClient: engine.client, maxRetries: 0);
  });
  tearDown(() => client.close());

  ChatParams prompt() => ChatParams(messages: [ChatMessage.user('Halo')]);

  test('create posts to the exact route without credentials or user agent',
      () async {
    final result = await client.chat.create(prompt());
    expect(result, isA<Ok<ChatCompletion>>());
    final request = engine.requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), route);
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(request.headers.containsKey('user-agent'), isFalse);
    expect((engine.bodies().single as Map<String, dynamic>)['stream'], false);
  });

  test('stream posts to the exact route and yields content', () async {
    engine.next(Scripted(chunks: [
      utf8.encode('${frame(chunk('Halo'))}${frame('[DONE]')}'),
    ]));
    final result = await client.chat.stream(prompt());
    expect(result, isA<Ok<ChatStream>>());
    final stream = (result as Ok<ChatStream>).data;
    expect(await stream.map((part) => part.delta).toList(), ['Halo']);
    expect(await stream.done, isNull);
    expect(engine.requests.single.url.toString(), route);
    expect(engine.requests.single.headers.containsKey('authorization'), false);
    expect(engine.requests.single.headers.containsKey('user-agent'), false);
    final body = engine.bodies().single as Map<String, dynamic>;
    expect(body['stream'], true);
    expect(body['stream_options'], {'include_usage': true});
  });

  for (final route in ['', '/api/meridian/chat']) {
    test('route "$route" refuses without a request', () async {
      final invalid = MeridianBrowser(route: route, httpClient: engine.client);
      final result = await invalid.chat.create(prompt());
      expect(result, isA<Err<ChatCompletion>>());
      final error = (result as Err<ChatCompletion>).error;
      expect(error.code, 'invalid_request');
      expect(error.message, contains('https://example.com/api/meridian/chat'));
      expect(engine.requests, isEmpty);
      invalid.close();
    });
  }

  test('generic nonretryable 503 is sent once', () async {
    engine.next(const Scripted(status: 503, json: {
      'error': {
        'code': 'service_unavailable',
        'type': 'api_error',
        'message': 'The service is temporarily unavailable.',
        'retryable': false,
      },
    }));
    final retrying = MeridianBrowser(route: route, httpClient: engine.client);
    final result = await retrying.chat.create(prompt());
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.retryable, false);
    expect(engine.requests, hasLength(1));
    retrying.close();
  });

  test('defaultRoutePath documents the app forwarding route', () {
    expect(defaultRoutePath, '/api/meridian/chat');
  });
}
