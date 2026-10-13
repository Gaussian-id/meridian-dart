import 'dart:convert';

import 'package:meridian/meridian.dart';
import 'package:test/test.dart' hide completion;

import 'support/fake_engine.dart';
import 'support/seams.dart';

void main() {
  // [1] Exercise every call through the injectable fake HTTP engine.
  late FakeEngine engine;
  late Meridian client;

  setUp(() {
    engine = FakeEngine();
    client = Meridian(
      url: FakeEngine.publicUrl,
      key: engine.projectKey,
      httpClient: engine.client,
      maxRetries: 0,
    );
    recordSleeps();
  });

  tearDown(() => client.close());

  ChatParams prompt({Map<String, Object?> extra = const {}}) => ChatParams(
        messages: [ChatMessage.user('Halo')],
        extra: extra,
      );

  test('create returns text and only the three token counts', () async {
    // [1] Include extra usage members that must be discarded.
    engine.next(Scripted(
      json: completion(content: 'Selamat pagi', usage: {
        'prompt_tokens': 3,
        'completion_tokens': 2,
        'total_tokens': 5,
        'prompt_tokens_details': {'cached_tokens': 1},
        'cost': 99,
      }),
    ));

    final result = await client.chat.create(prompt());

    expect(result, isA<Ok<ChatCompletion>>());
    final data = (result as Ok<ChatCompletion>).data;
    // [2] Check the returned model and its wire representation.
    expect(data.text, 'Selamat pagi');
    expect(data.usage?.promptTokens, 3);
    expect(data.usage?.completionTokens, 2);
    expect(data.usage?.totalTokens, 5);
    expect(
        (data.toJson()['usage'] as Map<String, Object?>).keys,
        unorderedEquals(
            ['prompt_tokens', 'completion_tokens', 'total_tokens']));
    expect(jsonEncode(data.toJson()), isNot(contains('cost')));
    expect(jsonEncode(data.toJson()), isNot(contains('prompt_tokens_details')));
  });

  test('create sends auth, leaves model absent and owns stream controls',
      () async {
    // [1] Try to override the SDK-owned stream fields through extras.
    final result = await client.chat.create(prompt(extra: {
      'stream': true,
      'stream_options': {'include_usage': true},
      'top_p': 0.8,
    }));

    expect(result, isA<Ok<ChatCompletion>>());
    expect(engine.requests, hasLength(1));
    final request = engine.requests.single;
    // [2] Inspect the request the engine actually received.
    expect(request.method, 'POST');
    expect(request.url.path, '/v1/chat/completions');
    expect(request.headers['authorization'], 'Bearer ${engine.projectKey}');
    final body = engine.bodies().single as Map<String, dynamic>;
    expect(body, isNot(contains('model')));
    expect(body['stream'], false);
    expect(body, isNot(contains('stream_options')));
    expect(body['top_p'], 0.8);
    final idempotencyKey = request.headers['idempotency-key'];
    expect(idempotencyKey, isNotNull);
    expect(idempotencyKey, matches(RegExp(r'^[\x21-\x7e]{1,255}$')));
  });

  test('engine errors preserve code, type, status, retryable and request id',
      () async {
    engine.next(engineError('invalid_api_key'));

    final result = await client.chat.create(prompt());

    expect(result, isA<Err<ChatCompletion>>());
    final error = (result as Err<ChatCompletion>).error;
    expect(error.code, 'invalid_api_key');
    expect(error.type, 'authentication_error');
    expect(error.status, 401);
    expect(error.retryable, false);
    expect(error.requestId, 'req_fake_1');
  });

  for (final (status, retryable) in [(502, true), (503, true), (404, false)]) {
    test('non-Meridian $status response keeps status and request id', () async {
      engine.next(Scripted(
        status: status,
        headers: {'x-request-id': 'req_header'},
        text: status == 503 ? '' : '<html>upstream response</html>',
      ));

      final result = await client.chat.create(prompt());

      expect(result, isA<Err<ChatCompletion>>());
      final error = (result as Err<ChatCompletion>).error;
      expect(error.code, 'network_error');
      expect(error.status, status);
      expect(error.retryable, retryable);
      expect(error.requestId, 'req_header');
    });
  }

  test('a 200 body containing error is an Err', () async {
    engine.next(Scripted(json: envelope('permission_denied')));
    final result = await client.chat.create(prompt());
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'permission_denied');
  });

  test('an unknown engine code is preserved without exposing it as code',
      () async {
    engine.next(Scripted(status: 500, json: envelope('future_engine_code')));
    final result = await client.chat.create(prompt());
    expect(result, isA<Err<ChatCompletion>>());
    final error = (result as Err<ChatCompletion>).error;
    expect(error.code, 'internal');
    expect(error.engineCode, 'future_engine_code');
    expect(error.message, contains('future_engine_code'));
  });

  const expectedStatuses = <String, int>{
    'invalid_request': 400,
    'invalid_api_key': 401,
    'key_revoked': 401,
    'key_expired': 401,
    'project_unavailable': 403,
    'organisation_unavailable': 403,
    'model_not_allowed': 403,
    'byok_required': 403,
    'project_host_mismatch': 403,
    'model_not_found': 404,
    'route_not_found': 404,
    'method_not_allowed': 405,
    'capability_unsupported': 400,
    'body_too_large': 413,
    'rate_limited': 429,
    'insufficient_credit': 402,
    'hard_limit_reached': 429,
    'entitlement_missing': 403,
    'idempotency_conflict': 409,
    'upstream_unavailable': 502,
    'upstream_error': 502,
    'deadline_exceeded': 504,
    'service_unavailable': 503,
    'internal': 500,
    'invalid_token': 401,
    'permission_denied': 403,
    'not_found': 404,
    'conflict': 409,
  };
  for (final entry in expectedStatuses.entries) {
    test('an engine ${entry.key} error retains HTTP ${entry.value}', () async {
      engine.next(engineError(entry.key));
      final result = await client.chat.create(prompt());
      expect(result, isA<Err<ChatCompletion>>());
      expect((result as Err<ChatCompletion>).error.status, entry.value);
    });
  }

  test('completion raw and JSON omit price keys at every depth', () async {
    // [1] Include priced fields at the top level and inside nested metadata.
    final response = completion();
    response['total_cost'] = 100;
    response['metadata'] = {
      'Cost_Charged': 12,
      'nested': [
        {'supplier_price': 9, 'safe': true},
      ],
    };
    engine.next(Scripted(json: response));

    final result = await client.chat.create(prompt());

    // [2] Neither public representation may retain a priced key.
    expect(result, isA<Ok<ChatCompletion>>());
    final data = (result as Ok<ChatCompletion>).data;
    expect(jsonEncode(data.raw), isNot(contains('cost')));
    expect(jsonEncode(data.raw), isNot(contains('Cost')));
    expect(jsonEncode(data.raw), isNot(contains('price')));
    expect(jsonEncode(data.toJson()), isNot(contains('cost')));
    expect(jsonEncode(data.toJson()), isNot(contains('Cost')));
    expect(jsonEncode(data.toJson()), isNot(contains('price')));
  });

  test('models.list returns the catalogue and sends GET /v1/models', () async {
    engine.next(const Scripted(json: {
      'object': 'list',
      'data': [
        {'id': 'meridian/auto', 'object': 'model', 'owned_by': 'meridian'},
      ],
    }));

    final result = await client.models.list();

    expect(result, isA<Ok<ModelList>>());
    expect((result as Ok<ModelList>).data.data.single.id, 'meridian/auto');
    expect(engine.requests.single.method, 'GET');
    expect(engine.requests.single.url.path, '/v1/models');
  });

  for (final badUrl in ['', 'ftp://x', '/relative']) {
    test('bad URL $badUrl is a configuration error without a request',
        () async {
      final invalid = Meridian(
        url: badUrl,
        key: engine.projectKey,
        httpClient: engine.client,
      );
      final result = await invalid.chat.create(prompt());
      expect(result, isA<Err<ChatCompletion>>());
      final error = (result as Err<ChatCompletion>).error;
      expect(error.code, 'invalid_request');
      expect(error.type, 'client_error');
      expect(error.status, 0);
      expect(error.retryable, false);
      expect(engine.requests, isEmpty);
      invalid.close();
    });
  }

  for (final badKey in ['', 'bad key', 'bad\nkey']) {
    test('missing or unsafe key is a configuration error without a request',
        () async {
      final invalid = Meridian(
        url: FakeEngine.publicUrl,
        key: badKey,
        httpClient: engine.client,
      );
      final result = await invalid.chat.create(prompt());
      expect(result, isA<Err<ChatCompletion>>());
      expect((result as Err<ChatCompletion>).error.code, 'invalid_request');
      expect(engine.requests, isEmpty);
      invalid.close();
    });
  }

  test('URL and key default from the environment reader', () async {
    fakeEnv({
      'MERIDIAN_URL': FakeEngine.publicUrl,
      'MERIDIAN_KEY': engine.projectKey
    });
    final fromEnv = Meridian(httpClient: engine.client);
    final result = await fromEnv.chat.create(prompt());
    expect(result, isA<Ok<ChatCompletion>>());
    expect(engine.requests.single.headers['authorization'],
        'Bearer ${engine.projectKey}');
    fromEnv.close();
  });

  for (final badKey in ['', 'x' * 256, 'bad key', 'badükey']) {
    test('invalid caller idempotency key refuses before sending', () async {
      final result = await client.chat.create(prompt(), idempotencyKey: badKey);
      expect(result, isA<Err<ChatCompletion>>());
      expect((result as Err<ChatCompletion>).error.code, 'invalid_request');
      expect(engine.requests, isEmpty);
    });
  }

  test('non-encodable extra body refuses before sending', () async {
    final result = await client.chat
        .create(prompt(extra: {'date': DateTime.utc(2026, 10, 14)}));
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'invalid_request');
    expect(engine.requests, isEmpty);
  });
}
