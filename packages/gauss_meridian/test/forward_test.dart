import 'dart:async';
import 'dart:convert';

import 'package:gauss_meridian/gauss_meridian.dart';
import 'package:gauss_meridian/shelf.dart';
import 'package:gauss_meridian/src/forward.dart'
    show appCredentialCodes, browserError;
import 'package:shelf/shelf.dart' show Handler, Request, Response;
import 'package:test/test.dart' hide completion;

import 'support/fake_engine.dart';
import 'support/seams.dart';

void main() {
  late FakeEngine engine;
  late Meridian server;
  var authorized = 0;
  var built = 0;

  setUp(() {
    engine = FakeEngine();
    server = Meridian(
      url: FakeEngine.publicUrl,
      key: engine.projectKey,
      httpClient: engine.client,
      maxRetries: 0,
    );
    authorized = 0;
    built = 0;
    recordSleeps();
  });
  tearDown(() => server.close());

  final endpoint = Uri.parse('http://app.test/api/meridian/chat');
  const validBody = '{"messages":[{"role":"user","content":"hello"}]}';

  Request request(
    String body, {
    String method = 'POST',
    String? contentType = 'application/json',
    Map<String, String> headers = const {},
  }) => Request(
    method,
    endpoint,
    headers: {'content-type': ?contentType, ...headers},
    body: body,
  );

  Handler handler({
    Authorize? authorize,
    ClientFactory? client,
    AllowRule allow = const AllowRule(),
  }) => meridianForwardHandler(
    authorize:
        authorize ??
        (incoming) {
          authorized++;
          return true;
        },
    client:
        client ??
        (incoming) {
          built++;
          return server;
        },
    allow: allow,
  );

  Future<(Response, Map<String, dynamic>)> send(
    Handler route,
    String body, {
    String method = 'POST',
    String? contentType = 'application/json',
    Map<String, String> headers = const {},
  }) async {
    final response = await route(
      request(body, method: method, contentType: contentType, headers: headers),
    );
    final decoded =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    return (response, decoded);
  }

  Map<String, dynamic> sentBody() =>
      engine.bodies().single as Map<String, dynamic>;

  test('only POST is accepted before authorization or engine access', () async {
    final (response, _) = await send(handler(), validBody, method: 'GET');
    expect(response.statusCode, 405);
    expect(response.headers['allow'], 'POST');
    expect(authorized, 0);
    expect(built, 0);
    expect(engine.requests, isEmpty);
  });

  for (final contentType in <String?>[
    'text/plain',
    null,
    'application/jsonx',
    'application/x-www-form-urlencoded',
  ]) {
    test('rejects content type $contentType before authorize', () async {
      final (response, _) = await send(
        handler(),
        validBody,
        contentType: contentType,
      );
      expect(response.statusCode, 415);
      expect(authorized, 0);
      expect(engine.requests, isEmpty);
    });
  }

  test('accepts case-insensitive JSON content type with parameters', () async {
    final (response, _) = await send(
      handler(),
      validBody,
      contentType: 'Application/JSON; charset=utf-8',
    );
    expect(response.statusCode, 200);
    expect(engine.requests, hasLength(1));
  });

  test('rejects a 9 MiB body before authorization', () async {
    final (response, body) = await send(handler(), 'x' * (9 * 1024 * 1024));
    expect(response.statusCode, 413);
    expect((body['error'] as Map)['code'], 'body_too_large');
    expect(authorized, 0);
    expect(engine.requests, isEmpty);
  });

  for (final value in <Object?>[false, null, 1, 'yes']) {
    test('authorize value $value is a refusal', () async {
      final (response, _) = await send(
        handler(authorize: (_) => value),
        validBody,
      );
      expect(response.statusCode, 403);
      expect(engine.requests, isEmpty);
    });
  }

  test(
    'synchronous and asynchronous authorization throws are refusals',
    () async {
      for (final authorize in <Authorize>[
        (_) => throw StateError('private'),
        (_) async => throw StateError('private'),
      ]) {
        final (response, body) = await send(
          handler(authorize: authorize),
          validBody,
        );
        expect(response.statusCode, 403);
        expect(jsonEncode(body), isNot(contains('private')));
      }
      expect(engine.requests, isEmpty);
    },
  );

  test('async true proceeds and authorize can read the body', () async {
    String? seen;
    final (response, _) = await send(
      handler(
        authorize: (Request incoming) async {
          seen = await incoming.readAsString();
          return true;
        },
      ),
      validBody,
    );
    expect(response.statusCode, 200);
    expect(seen, validBody);
    expect(engine.requests, hasLength(1));
  });

  test('authorize may return its own response unchanged', () async {
    final appResponse = Response(401, body: 'login', headers: {'x-app': 'yes'});
    final route = handler(authorize: (_) => appResponse);
    final response = await route(request(validBody));
    expect(identical(response, appResponse), isTrue);
    expect(await response.readAsString(), 'login');
    expect(engine.requests, isEmpty);
  });

  for (final bad in <String>[
    '{not json',
    'null',
    '[]',
    '"x"',
    '{"messages":[]}',
    '{"messages":"hi"}',
    '{"messages":["hi"]}',
    '{"messages":[{"role":1}]}',
  ]) {
    test('bad JSON body $bad gives 400 without sending', () async {
      final (response, _) = await send(handler(), bad);
      expect(response.statusCode, 400);
      expect(engine.requests, isEmpty);
    });
  }

  String nested(int depth) => jsonEncode({
    'messages': [
      {'role': 'user', 'content': 'hello', 'nested': _nest(depth)},
    ],
  });

  test('100-deep JSON is refused and 60-deep JSON is forwarded', () async {
    final route = handler();
    final (deepResponse, _) = await send(route, nested(100));
    expect(deepResponse.statusCode, 400);
    expect(engine.requests, isEmpty);
    final (shallowResponse, _) = await send(route, nested(60));
    expect(shallowResponse.statusCode, 200);
    expect(engine.requests, hasLength(1));
  });

  test(
    'copies only allowed fields and owns model and stream controls',
    () async {
      final route = handler(
        allow: const AllowRule(
          options: [
            'max_tokens',
            'temperature',
            'constructor',
            'n',
            'max_completion_tokens',
            'stream',
          ],
        ),
      );
      final body = jsonEncode({
        'messages': [ChatMessage.user('hello').toJson()],
        'max_tokens': 1000000,
        'temperature': 0.3,
        'constructor': 1,
        'model': 'hidden',
        'tools': [1],
        'x': true,
        'n': 3,
        'max_completion_tokens': 999,
        'stream': false,
        'stream_options': {'include_usage': false},
      });
      final (response, _) = await send(route, body);
      expect(response.statusCode, 200);
      final sent = sentBody();
      expect(
        sent['messages'],
        (jsonDecode(body) as Map<String, dynamic>)['messages'],
      );
      expect(sent['max_tokens'], 4096);
      expect(sent['temperature'], 0.3);
      expect(sent['constructor'], 1);
      expect(sent['stream'], false);
      for (final key in [
        'model',
        'tools',
        'x',
        'n',
        'max_completion_tokens',
        'stream_options',
      ]) {
        expect(sent, isNot(contains(key)), reason: key);
      }
    },
  );

  test('messages without content reach the engine unchanged', () async {
    final body = jsonEncode({
      'messages': [
        {'role': 'user'},
      ],
    });
    final (response, _) = await send(handler(), body);
    final expected = jsonDecode(body) as Map<String, dynamic>;
    expect(response.statusCode, 200);
    expect(sentBody()['messages'], expected['messages']);
  });

  for (final (value, expected) in <(Object, int)>[
    (-7, 1),
    (2.9, 2),
    ('50', 4096),
    (100, 100),
  ]) {
    test('max_tokens $value clamps to $expected', () async {
      final (response, _) = await send(
        handler(),
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'max_tokens': value,
        }),
      );
      expect(response.statusCode, 200);
      expect(sentBody()['max_tokens'], expected);
    });
  }

  for (final (cap, expected) in <(int, int)>[
    (0, 4096),
    (-5, 4096),
    (1099511627776, 2147483647),
  ]) {
    test('token cap $cap becomes $expected', () async {
      final (response, _) = await send(
        handler(allow: AllowRule(maxTokensCap: cap)),
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'max_tokens': 1099511627776,
        }),
      );
      expect(response.statusCode, 200);
      expect(sentBody()['max_tokens'], expected);
    });
  }

  for (final temperature in <Object?>['0.3', null]) {
    test('invalid temperature $temperature is dropped', () async {
      final (response, _) = await send(
        handler(),
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'temperature': temperature,
        }),
      );
      expect(response.statusCode, 200);
      expect(sentBody(), isNot(contains('temperature')));
    });
  }

  test('model is forwarded only by list or anyModel rule', () async {
    for (final (allow, model, expected) in <(AllowRule, String, String?)>[
      (const AllowRule(models: ['m1']), 'm1', 'm1'),
      (const AllowRule(models: ['m1']), 'm2', null),
      (const AllowRule(anyModel: true), 'm3', 'm3'),
    ]) {
      final (response, _) = await send(
        handler(allow: allow),
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'model': model,
        }),
      );
      expect(response.statusCode, 200);
      final sent = engine.bodies().last as Map<String, dynamic>;
      expect(sent['model'], expected);
    }
  });

  for (final key in <String>['k-123', '', 'a b', 'ü']) {
    test('idempotency key $key is safely forwarded or replaced', () async {
      final (response, _) = await send(
        handler(),
        validBody,
        headers: {'idempotency-key': key},
      );
      expect(response.statusCode, 200);
      final sent = engine.requests.single.headers['idempotency-key'];
      expect(sent, matches(RegExp(r'^[\x21-\x7e]{1,255}$')));
      expect(sent == key, key == 'k-123');
    });
  }

  test('300-character browser idempotency key is replaced', () async {
    final (response, _) = await send(
      handler(),
      validBody,
      headers: {'idempotency-key': 'x' * 300},
    );
    expect(response.statusCode, 200);
    final sent = engine.requests.single.headers['idempotency-key'];
    expect(sent, matches(RegExp(r'^[\x21-\x7e]{1,255}$')));
    expect(sent, isNot('x' * 300));
  });

  test(
    'stream relays engine bytes, SSE headers, request id and usage request',
    () async {
      final wire =
          frame(chunk('hello')) + frame(usageChunk()) + frame('[DONE]');
      engine.next(
        Scripted(
          headers: {'x-request-id': 'req_stream'},
          chunks: [utf8.encode(wire)],
        ),
      );
      final response = await handler()(
        request(
          jsonEncode({
            'messages': [
              {'role': 'user'},
            ],
            'stream': true,
          }),
        ),
      );
      expect(response.statusCode, 200);
      expect(
        response.headers['content-type'],
        'text/event-stream; charset=utf-8',
      );
      expect(response.headers['cache-control'], 'no-cache');
      expect(response.headers['x-request-id'], 'req_stream');
      expect(response.context['shelf.io.buffer_output'], false);
      expect(await response.readAsString(), wire);
      final sent = sentBody();
      expect(sent['stream'], true);
      expect(sent['stream_options'], {'include_usage': true});
    },
  );

  test('buffered response returns completion JSON and request id', () async {
    engine.next(
      Scripted(headers: {'x-request-id': 'req_buffered'}, json: completion()),
    );
    final (response, body) = await send(handler(), validBody);
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('application/json'));
    expect(response.headers['x-request-id'], 'req_buffered');
    expect(body['object'], 'chat.completion');
  });

  const hidden = <String>[
    'invalid_api_key',
    'key_revoked',
    'key_expired',
    'project_unavailable',
    'organisation_unavailable',
    'project_host_mismatch',
    'byok_required',
    'insufficient_credit',
    'hard_limit_reached',
    'entitlement_missing',
  ];

  test('browserError keeps safe errors identical and hides app errors', () {
    expect(appCredentialCodes, unorderedEquals(hidden));
    const ordinary = MeridianError(
      code: 'invalid_request',
      type: 'invalid_request_error',
      status: 400,
      message: 'bad request',
      retryable: false,
    );
    expect(identical(browserError(ordinary), ordinary), isTrue);
    const privateError = MeridianError(
      code: 'invalid_api_key',
      type: 'authentication_error',
      status: 401,
      message: 'private',
      retryable: false,
      requestId: 'req_safe',
    );
    final publicError = browserError(privateError);
    expect(publicError.code, 'service_unavailable');
    expect(publicError.status, 503);
    expect(publicError.retryable, false);
    expect(publicError.message, 'The service is temporarily unavailable.');
    expect(publicError.requestId, 'req_safe');
  });

  for (final code in hidden) {
    test('hides $code behind generic non-retryable 503', () async {
      engine.next(engineError(code));
      final (response, body) = await send(handler(), validBody);
      expect(response.statusCode, 503);
      final error = body['error'] as Map<String, dynamic>;
      expect(error, {
        'message': 'The service is temporarily unavailable.',
        'type': 'api_error',
        'code': 'service_unavailable',
        'request_id': 'req_fake_1',
        'retryable': false,
      });
      expect(response.headers, isNot(contains('retry-after')));
      expect(jsonEncode(body), isNot(contains(code)));
    });
  }

  test('server client still sees real app credential code', () async {
    engine.next(engineError('insufficient_credit'));
    final reply = await server.chat.create(
      ChatParams(messages: [ChatMessage.user('hello')]),
    );
    expect(reply, isA<Err<ChatCompletion>>());
    expect((reply as Err<ChatCompletion>).error.code, 'insufficient_credit');
  });

  for (final (code, status) in <(String, int)>[
    ('invalid_request', 400),
    ('model_not_allowed', 403),
    ('rate_limited', 429),
  ]) {
    test('passes end-user $code with HTTP $status', () async {
      engine.next(engineError(code, headers: {'retry-after': '7'}));
      final (response, body) = await send(handler(), validBody);
      expect(response.statusCode, status);
      expect((body['error'] as Map)['code'], code);
      expect(
        response.headers['retry-after'],
        code == 'rate_limited' ? '7' : null,
      );
    });
  }

  test('other engine Retry-After is not relayed', () async {
    engine.next(
      engineError('upstream_unavailable', headers: {'retry-after': '5'}),
    );
    final (response, body) = await send(handler(), validBody);
    expect(response.statusCode, 502);
    expect((body['error'] as Map)['code'], 'upstream_unavailable');
    expect(response.headers, isNot(contains('retry-after')));
  });

  for (final badCode in <Object?>['future_error', null, '', 3]) {
    test('unknown or malformed engine code $badCode is generic', () async {
      engine.next(
        Scripted(
          status: 500,
          json: {
            'error': {
              'message': 'private details',
              'type': 'api_error',
              'code': ?badCode,
            },
          },
        ),
      );
      final (response, body) = await send(handler(), validBody);
      expect(response.statusCode, 503);
      expect((body['error'] as Map)['code'], 'service_unavailable');
      expect(jsonEncode(body), isNot(contains('private details')));
    });
  }

  test('a 200 reply containing an error is generic', () async {
    engine.next(Scripted(json: envelope('invalid_api_key')));
    final (response, body) = await send(handler(), validBody);
    expect(response.statusCode, 503);
    expect((body['error'] as Map)['code'], 'service_unavailable');
  });

  test('misconfigured client gives generic 503 without key detail', () async {
    final route = handler(
      client: (_) => Meridian(
        url: FakeEngine.publicUrl,
        key: '',
        httpClient: engine.client,
      ),
    );
    final (response, body) = await send(route, validBody);
    expect(response.statusCode, 503);
    expect(jsonEncode(body).toLowerCase(), isNot(contains('key')));
    expect(engine.requests, isEmpty);
  });

  test(
    'throwing factory gives generic 503 and client builds per request',
    () async {
      final failing = handler(client: (_) => throw StateError('secret'));
      final (failure, body) = await send(failing, validBody);
      expect(failure.statusCode, 503);
      expect((body['error'] as Map)['code'], 'service_unavailable');
      expect(engine.requests, isEmpty);
      final route = handler();
      await send(route, validBody);
      await send(route, validBody);
      expect(built, 2);
    },
  );

  test('byte-split hidden error after text becomes generic frame', () async {
    final privateFrame = frame(envelope('insufficient_credit'));
    final wire = frame(chunk('hello'));
    engine.next(
      Scripted(
        headers: {'x-request-id': 'req_stream'},
        chunks: [
          utf8.encode(wire),
          ...utf8.encode(privateFrame).map((byte) => <int>[byte]),
        ],
      ),
    );
    final response = await handler()(
      request(
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'stream': true,
        }),
      ),
    );
    final relayed = await response.readAsString();
    expect(response.statusCode, 200);
    expect(relayed, startsWith(wire));
    expect(relayed, contains('"code":"service_unavailable"'));
    expect(relayed, contains('req_fake_1'));
    expect(relayed, isNot(contains('insufficient_credit')));
  });

  for (final hiddenCode in [true, false]) {
    test(
      '200 KB ${hiddenCode ? 'hidden' : 'ordinary'} frame is handled',
      () async {
        final payload = hiddenCode
            ? frame({
                'error': {
                  'message': 'x' * (200 * 1024),
                  'type': 'rate_limit_error',
                  'code': 'insufficient_credit',
                },
              })
            : frame(chunk('x' * (200 * 1024)));
        final bytes = utf8.encode(payload);
        final pieces = <List<int>>[
          for (var offset = 0; offset < bytes.length; offset += 512)
            bytes.sublist(
              offset,
              offset + 512 > bytes.length ? bytes.length : offset + 512,
            ),
        ];
        if (!hiddenCode) pieces.add(utf8.encode(frame('[DONE]')));
        engine.next(Scripted(chunks: pieces));
        final response = await handler()(
          request(
            jsonEncode({
              'messages': [
                {'role': 'user'},
              ],
              'stream': true,
            }),
          ),
        );
        final relayed = await response.readAsString();
        if (hiddenCode) {
          expect(relayed, contains('"code":"service_unavailable"'));
          expect(relayed, isNot(contains('insufficient_credit')));
          expect(relayed.length, lessThan(1000));
        } else {
          expect(relayed, payload + frame('[DONE]'));
        }
      },
    );
  }

  test('ordinary mid-stream error passes unchanged', () async {
    final wire = frame(chunk('hello')) + frame(envelope('upstream_error'));
    engine.next(Scripted(chunks: [utf8.encode(wire)]));
    final response = await handler()(
      request(
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'stream': true,
        }),
      ),
    );
    expect(await response.readAsString(), wire);
  });

  test('truncated stream ends in generic frame', () async {
    engine.next(Scripted(chunks: [utf8.encode(frame(chunk('hello')))]));
    final response = await handler()(
      request(
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'stream': true,
        }),
      ),
    );
    final relayed = await response.readAsString();
    expect(relayed, startsWith(frame(chunk('hello'))));
    expect(relayed, contains('"code":"service_unavailable"'));
  });

  test('unsafe request id never reaches a header or body', () async {
    engine.next(
      Scripted(
        status: 401,
        headers: {'x-request-id': 'bad\r\nid'},
        json: envelope('invalid_api_key', requestId: 'bad\r\nid'),
      ),
    );
    final (response, body) = await send(handler(), validBody);
    expect(response.statusCode, 503);
    expect(response.headers, isNot(contains('x-request-id')));
    expect((body['error'] as Map), isNot(contains('request_id')));
  });

  test(
    'unsafe request id is removed from an ordinary stream error frame',
    () async {
      final unsafe = frame({
        'error': {
          'message': 'upstream failed',
          'type': 'api_error',
          'code': 'upstream_error',
          'request_id': 'bad\r\nid',
        },
      });
      engine.next(Scripted(chunks: [utf8.encode(unsafe)]));
      final response = await handler()(
        request(
          jsonEncode({
            'messages': [
              {'role': 'user'},
            ],
            'stream': true,
          }),
        ),
      );
      final wire = await response.readAsString();
      expect(wire, contains('"code":"upstream_error"'));
      expect(wire, isNot(contains('bad\\r\\nid')));
      expect(wire, isNot(contains('request_id')));
    },
  );

  test('unsafe request id in a buffered body is removed', () async {
    final reply = completion()..['request_id'] = 'bad\r\nid';
    engine.next(Scripted(json: reply));
    final (response, body) = await send(handler(), validBody);
    expect(response.statusCode, 200);
    expect(body, isNot(contains('request_id')));
    expect(response.headers, isNot(contains('x-request-id')));
  });

  test('cancelling response body cancels fake upstream', () async {
    engine.next(
      Scripted(
        chunks: [
          utf8.encode(frame(chunk('first'))),
          utf8.encode(frame(chunk('second'))),
        ],
        hang: true,
      ),
    );
    final response = await handler()(
      request(
        jsonEncode({
          'messages': [
            {'role': 'user'},
          ],
          'stream': true,
        }),
      ),
    );
    final first = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.read().listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    await subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(engine.upstreamCancels, 1);
  });
}

Object? _nest(int depth) {
  Object? value = 'leaf';
  for (var index = 0; index < depth; index++) {
    value = [value];
  }
  return value;
}
