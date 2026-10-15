import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Start the loopback SSE fixture in the test runner's VM isolate.
Future<void> hybridMain(dynamic channel) async {
  // [1] Bind only to loopback and publish the ephemeral port to Chrome.
  final server = await shelf_io.serve(_handle, InternetAddress.loopbackIPv4, 0);
  // The hybrid channel is dynamic so this fixture needs no extra dependency.
  // ignore: avoid_dynamic_calls
  channel.sink.add(server.port);
  // [2] Let the test runner close the channel to stop the fixture.
  // ignore: avoid_dynamic_calls
  await channel.stream.drain<void>();
  await server.close(force: true);
}

Future<Response> _handle(Request request) async {
  // [1] Allow the browser's JSON POST preflight from the test page origin.
  const cors = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'content-type, idempotency-key',
  };
  if (request.method == 'OPTIONS') return Response.ok('', headers: cors);
  if (request.method != 'POST' || request.url.path != 'chat') {
    return Response.notFound('', headers: cors);
  }

  // [2] Consume the request before writing distinct, timed SSE body parts.
  await request.readAsString();
  return Response.ok(
    _frames(),
    context: {'shelf.io.buffer_output': false},
    headers: {
      ...cors,
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache',
    },
  );
}

Stream<List<int>> _frames() async* {
  yield utf8.encode('data: ${jsonEncode(_chunk('first'))}\n\n');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  yield utf8.encode('data: ${jsonEncode(_chunk('last'))}\n\n');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  yield utf8.encode('data: [DONE]\n\n');
}

Map<String, Object?> _chunk(String text) => {
  'choices': [
    {
      'delta': {'content': text},
    },
  ],
};
