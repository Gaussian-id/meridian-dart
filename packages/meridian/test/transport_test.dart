import 'dart:async';

import 'package:meridian/meridian.dart';
import 'package:meridian/src/clock.dart' as clock;
import 'package:test/test.dart' hide completion;

import 'support/fake_engine.dart';
import 'support/seams.dart';

void main() {
  late FakeEngine engine;
  late List<Duration> sleeps;

  setUp(() {
    engine = FakeEngine();
    sleeps = recordSleeps();
  });

  Meridian client({int? maxRetries, Duration? timeout}) {
    final instance = Meridian(
      url: FakeEngine.publicUrl,
      key: engine.projectKey,
      httpClient: engine.client,
      maxRetries: maxRetries,
      timeout: timeout,
    );
    addTearDown(instance.close);
    return instance;
  }

  ChatParams prompt() => ChatParams(messages: [ChatMessage.user('hi')]);

  test('two retries return the last upstream error', () async {
    engine.next(
        engineError('upstream_unavailable'),
        engineError('upstream_unavailable'),
        engineError('upstream_unavailable'));

    final result = await client().chat.create(prompt());

    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'upstream_unavailable');
    expect(engine.requests, hasLength(3));
    expect(sleeps, hasLength(2));
  });

  for (final (retries, expected) in [(0, 1), (-1, 3), (99, 3)]) {
    test('maxRetries $retries sends $expected request(s)', () async {
      engine.next(
          engineError('upstream_unavailable'),
          engineError('upstream_unavailable'),
          engineError('upstream_unavailable'));

      final result = await client(maxRetries: retries).chat.create(prompt());

      expect(result, isA<Err<ChatCompletion>>());
      expect(engine.requests, hasLength(expected));
      expect(sleeps, hasLength(expected - 1));
    });
  }

  test('a non-retryable error is sent once without waiting', () async {
    engine.next(engineError('invalid_request'));

    final result = await client().chat.create(prompt());

    expect((result as Err<ChatCompletion>).error.code, 'invalid_request');
    expect(engine.requests, hasLength(1));
    expect(sleeps, isEmpty);
  });

  test('a retry reuses the same generated idempotency key', () async {
    engine.next(
        engineError('service_unavailable'), Scripted(json: completion()));

    final result = await client().chat.create(prompt());

    expect(result, isA<Ok<ChatCompletion>>());
    expect(engine.requests, hasLength(2));
    final keys = engine.requests
        .map((request) => request.headers['idempotency-key'])
        .toSet();
    expect(keys, hasLength(1));
    expect(keys.single, isNotNull);
  });

  test('a caller idempotency key is sent on every attempt', () async {
    engine.next(engineError('rate_limited'), Scripted(json: completion()));

    final result =
        await client().chat.create(prompt(), idempotencyKey: 'caller-key-1');

    expect(result, isA<Ok<ChatCompletion>>());
    expect(engine.requests.map((request) => request.headers['idempotency-key']),
        ['caller-key-1', 'caller-key-1']);
  });

  for (final (value, seconds) in [('2', 2), ('30', 30)]) {
    test('Retry-After $value waits exactly $seconds seconds', () async {
      engine.next(engineError('rate_limited', headers: {'retry-after': value}),
          Scripted(json: completion()));

      final result = await client().chat.create(prompt());

      expect(result, isA<Ok<ChatCompletion>>());
      expect(sleeps, [Duration(seconds: seconds)]);
      expect(engine.requests, hasLength(2));
    });
  }

  for (final value in ['31', '3600']) {
    test('Retry-After $value returns immediately with the request id',
        () async {
      engine.next(engineError('rate_limited', headers: {'retry-after': value}));

      final result = await client().chat.create(prompt());

      expect(result, isA<Err<ChatCompletion>>());
      final error = (result as Err<ChatCompletion>).error;
      expect(error.code, 'rate_limited');
      expect(error.requestId, 'req_fake_1');
      expect(engine.requests, hasLength(1));
      expect(sleeps, isEmpty);
    });
  }

  for (final value in [
    '0',
    ' ',
    '1e3',
    '0x10',
    '-5',
    'Wed, 21 Oct 2015 07:28:00 GMT',
    '9' * 400,
  ]) {
    test(
        'odd Retry-After ${value.length > 40 ? '400 digits' : value} backs off',
        () async {
      engine.next(engineError('rate_limited', headers: {'retry-after': value}),
          Scripted(json: completion()));

      final result = await client().chat.create(prompt());

      expect(result, isA<Ok<ChatCompletion>>());
      expect(sleeps, hasLength(1));
      expect(sleeps.single,
          greaterThanOrEqualTo(const Duration(milliseconds: 500)));
      expect(sleeps.single, lessThan(const Duration(milliseconds: 750)));
      expect(engine.requests, hasLength(2));
    });
  }

  test('a header timeout retries and returns a typed network error', () async {
    engine.next(const Scripted(headersNever: true),
        const Scripted(headersNever: true), const Scripted(headersNever: true));

    final result = await client(timeout: const Duration(milliseconds: 50))
        .chat
        .create(prompt());

    expect(result, isA<Err<ChatCompletion>>());
    final error = (result as Err<ChatCompletion>).error;
    expect(error.code, 'network_error');
    expect(error.retryable, true);
    expect(error.message, contains('No response within'));
    expect(engine.requests, hasLength(3));
    expect(sleeps, hasLength(2));
  });

  test('a successful stream outlives its header timeout', () async {
    engine.next(Scripted(
        chunks: [frame(chunk('still working')).codeUnits], hang: true));
    final result = await client(timeout: const Duration(milliseconds: 40))
        .chat
        .stream(prompt());
    expect(result, isA<Ok<ChatStream>>());
    final stream = (result as Ok<ChatStream>).data;
    final first = Completer<void>();
    var ended = false;
    final subscription = stream.listen((_) => first.complete());
    addTearDown(() async {
      await stream.cancel();
      await subscription.cancel();
    });
    unawaited(stream.done.then((_) => ended = true));

    await first.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ended, isFalse);
    expect(stream.error, isNull);
  });

  test('a buffered JSON response keeps its body timeout', () async {
    engine.next(Scripted(json: completion(), hang: true));
    final result = await client(
      timeout: const Duration(milliseconds: 40),
      maxRetries: 0,
    ).chat.create(prompt()).timeout(const Duration(seconds: 1));
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'network_error');
  });

  test('a network failure followed by success returns the completion',
      () async {
    engine.next(const Scripted(networkError: true),
        Scripted(json: completion(content: 'ok')));

    final result = await client().chat.create(prompt());

    expect(result, isA<Ok<ChatCompletion>>());
    expect((result as Ok<ChatCompletion>).data.text, 'ok');
    expect(engine.requests, hasLength(2));
  });

  for (final previous in ['upstream_unavailable', 'rate_limited']) {
    test('$previous followed by idempotency conflict keeps the right error',
        () async {
      engine.next(engineError(previous), engineError('idempotency_conflict'));

      final result = await client().chat.create(prompt());

      expect(result, isA<Err<ChatCompletion>>());
      expect((result as Err<ChatCompletion>).error.code,
          previous == 'rate_limited' ? 'idempotency_conflict' : previous);
      expect(engine.requests, hasLength(2));
    });
  }

  test('a conflict on the first attempt is returned as is', () async {
    engine.next(engineError('idempotency_conflict'));

    final result = await client().chat.create(prompt());

    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'idempotency_conflict');
    expect(engine.requests, hasLength(1));
    expect(sleeps, isEmpty);
  });

  test('an abort interrupts a backoff that never finishes', () async {
    // [1] Let the first error reach the backoff, which deliberately never ends.
    final sleeping = Completer<void>();
    clock.sleeper = (duration) {
      sleeps.add(duration);
      sleeping.complete();
      return Completer<void>().future;
    };
    final abort = Completer<void>();
    engine.next(engineError('upstream_unavailable'));
    final pending = client().chat.create(prompt(), abortTrigger: abort.future);
    await sleeping.future.timeout(const Duration(seconds: 1));

    // [2] Caller cancellation must win without waiting on the sleeper.
    abort.complete();
    final result = await pending.timeout(const Duration(seconds: 1));
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'aborted');
    expect(engine.requests, hasLength(1));
  });

  test('an abort while waiting for headers reaches the fake engine', () async {
    // [1] Start a request whose headers never arrive, then cancel it.
    final abort = Completer<void>();
    engine.next(const Scripted(headersNever: true));
    final pending = client().chat.create(prompt(), abortTrigger: abort.future);
    while (engine.requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    // [2] The public result is aborted and the HTTP abort trigger fires.
    abort.complete();
    final result = await pending.timeout(const Duration(seconds: 1));
    expect(result, isA<Err<ChatCompletion>>());
    expect((result as Err<ChatCompletion>).error.code, 'aborted');
    await Future<void>.delayed(Duration.zero);
    expect(engine.aborts, greaterThanOrEqualTo(1));
  });
}
