import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/admin.dart' as admin;
import 'package:meridian/meridian.dart' as server;
import 'package:meridian_flutter/meridian_flutter.dart';

import '../../meridian/test/support/fake_engine.dart';

void main() {
  const route = 'https://example.com/api/meridian/chat';

  ChatParams prompt() => ChatParams(messages: [ChatMessage.user('Halo')]);

  test('browser refuses a relative route without sending a request', () async {
    final engine = FakeEngine();
    final client = MeridianBrowser(
      route: '/api/meridian/chat',
      httpClient: engine.client,
    );

    final result = await client.chat.create(prompt());

    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'invalid_request');
    expect(engine.requests, isEmpty);
    client.close();
  });

  test('browser sends no authorization header from Flutter', () async {
    final engine = FakeEngine();
    final client = MeridianBrowser(route: route, httpClient: engine.client);

    final result = await client.chat.create(prompt());

    expect(result, isA<Ok<ChatCompletion>>());
    expect(engine.requests, hasLength(1));
    expect(
      engine.requests.single.headers.containsKey('authorization'),
      isFalse,
    );
    client.close();
  });

  testWidgets('StreamBuilder renders chat chunks', (tester) async {
    final engine = FakeEngine()
      ..next(
        Scripted(
          chunks: [
            utf8.encode(
              '${frame(chunk('Hello'))}${frame(chunk(' world'))}'
              '${frame('[DONE]')}',
            ),
          ],
        ),
      );
    final client = MeridianBrowser(route: route, httpClient: engine.client);
    final result = await client.chat.stream(prompt());
    expect(result, isA<Ok<ChatStream>>());
    final stream = (result as Ok<ChatStream>).data;

    await tester.pumpWidget(
      MaterialApp(
        home: StreamBuilder<ChatChunk>(
          stream: stream,
          builder: (context, snapshot) => Text(snapshot.data?.delta ?? ''),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await stream.done;
    await tester.pump();

    expect(find.text(' world'), findsOneWidget);
    expect(stream.error, isNull);
    expect(
      engine.requests.single.headers.containsKey('authorization'),
      isFalse,
    );
    client.close();
  });

  testWidgets('disposing StreamBuilder mid-stream aborts upstream once', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..next(
        Scripted(chunks: [utf8.encode(frame(chunk('First')))], hang: true),
      );
    final client = MeridianBrowser(route: route, httpClient: engine.client);
    final result = await client.chat.stream(prompt());
    expect(result, isA<Ok<ChatStream>>());
    final stream = (result as Ok<ChatStream>).data;

    await tester.pumpWidget(
      MaterialApp(
        home: StreamBuilder<ChatChunk>(
          stream: stream,
          builder: (context, snapshot) => Text(snapshot.data?.delta ?? ''),
        ),
      ),
    );
    for (
      var attempt = 0;
      attempt < 5 && find.text('First').evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.text('First'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect((await stream.done)?.code, 'aborted');
    expect(engine.upstreamCancels, 1);
    expect(tester.takeException(), isNull);
    client.close();
  });

  test('server Meridian refuses to run in Flutter', () async {
    final engine = FakeEngine();
    final client = server.Meridian(
      url: FakeEngine.publicUrl,
      key: engine.projectKey,
      httpClient: engine.client,
    );

    final result = await client.chat.create(prompt());

    expect(result, isA<server.Err<server.ChatCompletion>>());
    final error = (result as server.Err<server.ChatCompletion>).error;
    expect(error.code, 'invalid_request');
    expect(error.type, 'client_error');
    expect(error.message, contains('MeridianBrowser'));
    expect(engine.requests, isEmpty);
    client.close();
  });

  test('MeridianAdmin refuses provisioning in Flutter', () async {
    final engine = FakeEngine();
    final client = admin.MeridianAdmin(
      url: FakeEngine.adminUrl,
      key: engine.integratorKey,
      httpClient: engine.client,
    );

    final result = await client.models.list();

    expect(result, isA<admin.Err<Object>>());
    final error = (result as admin.Err<Object>).error;
    expect(error.code, 'invalid_request');
    expect(error.type, 'client_error');
    expect(error.message, contains('Provisioning belongs on a server'));
    expect(engine.requests, isEmpty);
    client.close();
  });

  test('Flutter entry library reaches only the browser API', () {
    final source = File('lib/meridian_flutter.dart').readAsStringSync();
    final directive = RegExp(r'''\b(?:import|export)\s+['"]([^'"]+)['"]''');
    final imports = directive
        .allMatches(source)
        .map((match) => match.group(1))
        .toSet();

    expect(imports, contains('package:meridian/browser.dart'));
    expect(
      imports,
      everyElement(
        anyOf('package:meridian/browser.dart', startsWith('package:flutter/')),
      ),
    );
  });
}
