import 'dart:async';
import 'dart:convert';

import 'package:meridian/meridian.dart';
import 'package:meridian/src/sse.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';

void main() {
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
  });
  tearDown(() => client.close());

  ChatParams prompt({Map<String, Object?> extra = const {}}) => ChatParams(
        messages: [ChatMessage.user('Halo')],
        extra: extra,
      );

  Future<ChatStream> start({Future<void>? abortTrigger}) async {
    final result =
        await client.chat.stream(prompt(), abortTrigger: abortTrigger);
    expect(result, isA<Ok<ChatStream>>());
    return (result as Ok<ChatStream>).data;
  }

  void answer(String wire, {String requestId = 'req_stream_1'}) {
    engine.next(Scripted(
      headers: {'x-request-id': requestId},
      chunks: [utf8.encode(wire)],
    ));
  }

  test('text chunks and usage arrive; caller cannot override stream controls',
      () async {
    answer('${frame(chunk('Hel'))}${frame(chunk('lo'))}'
        '${frame(usageChunk())}${frame('[DONE]')}');
    final result = await client.chat.stream(prompt(extra: {
      'stream': false,
      'stream_options': {'include_usage': false},
      'top_p': 0.8,
    }));
    expect(result, isA<Ok<ChatStream>>());
    final stream = (result as Ok<ChatStream>).data;

    expect(await stream.map((part) => part.delta).toList(), ['Hel', 'lo']);
    expect(stream.usage?.promptTokens, 3);
    expect(stream.usage?.completionTokens, 2);
    expect(stream.usage?.totalTokens, 5);
    expect(stream.requestId, 'req_stream_1');
    expect(await stream.done, isNull);
    expect(stream.error, isNull);
    final body = engine.bodies().single as Map<String, dynamic>;
    expect(body['stream'], true);
    expect(body['stream_options'], {'include_usage': true});
    expect(body['top_p'], 0.8);
  });

  test('SSE decoder holds trailing CR and joins multiple data fields', () {
    final decoder = SseDecoder();
    expect(decoder.add(utf8.encode(': comment\rdata: first\r')), isEmpty);
    expect(decoder.add(utf8.encode('\ndata: second\r\n\r')), isEmpty);
    expect(decoder.add(utf8.encode('\n')), ['first\nsecond']);
    expect(decoder.close(), isEmpty);
  });

  test('CRLF frames split between CR and LF preserve an emoji', () async {
    final wire =
        '${frame(chunk('😀'))}${frame('[DONE]')}'.replaceAll('\n', '\r\n');
    final bytes = utf8.encode(wire);
    final cr = bytes.indexOf(13);
    final emoji = utf8.encode('😀');
    final emojiStart = wire.indexOf('😀');
    final prefixBytes = utf8.encode(wire.substring(0, emojiStart)).length;
    expect(cr, greaterThan(0));
    expect(emoji, hasLength(4));
    engine.next(Scripted(chunks: [
      bytes.sublist(0, prefixBytes + 2),
      bytes.sublist(prefixBytes + 2, cr + 1),
      bytes.sublist(cr + 1),
    ]));

    final stream = await start();
    expect(await stream.map((part) => part.delta).toList(), ['😀']);
    expect(await stream.done, isNull);
  });

  test('byte-at-a-time CRLF frames decode without losing data', () async {
    final wire =
        '${frame(chunk('😀Hi'))}${frame('[DONE]')}'.replaceAll('\n', '\r\n');
    engine.next(Scripted(chunks: [
      for (final byte in utf8.encode(wire)) [byte],
    ]));

    final stream = await start();
    expect(await stream.map((part) => part.delta).toList(), ['😀Hi']);
    expect(await stream.done, isNull);
  });

  test('multi-line data field split after CR is one JSON event', () async {
    final json = jsonEncode(chunk('joined'));
    final split = json.indexOf(',');
    final wire = 'data: ${json.substring(0, split + 1)}\r'
        'data: ${json.substring(split + 1)}\r\n\r\n'
        'data: [DONE]\r\n\r\n';
    final bytes = utf8.encode(wire);
    final firstCr = bytes.indexOf(13);
    engine.next(Scripted(chunks: [
      bytes.sublist(0, firstCr + 1),
      bytes.sublist(firstCr + 1),
    ]));

    final stream = await start();
    expect(await stream.map((part) => part.delta).toList(), ['joined']);
    expect(await stream.done, isNull);
  });

  test('mid-stream engine error preserves preceding chunks and typed end',
      () async {
    answer('${frame(chunk('before'))}${frame(envelope('upstream_error'))}');
    final stream = await start();

    expect(await stream.map((part) => part.delta).toList(), ['before']);
    expect(stream.error?.code, 'upstream_error');
    expect(stream.error?.status, 502);
    expect((await stream.done)?.code, 'upstream_error');
  });

  test('dropped connection ends as network_error without an error event',
      () async {
    engine.next(Scripted(
        chunks: [utf8.encode(frame(chunk('before')))],
        dropAfter: 1,
        headers: {'x-request-id': 'req_drop'}));
    final stream = await start();

    expect(await stream.map((part) => part.delta).toList(), ['before']);
    expect(stream.error?.code, 'network_error');
    expect(stream.error?.requestId, 'req_drop');
    expect((await stream.done)?.code, 'network_error');
  });

  test('EOF without DONE is a network_error', () async {
    answer(frame(chunk('partial')));
    final stream = await start();

    expect(await stream.map((part) => part.delta).toList(), ['partial']);
    expect(stream.error?.code, 'network_error');
    expect((await stream.done)?.code, 'network_error');
  });

  test('an unterminated DONE frame remains a truncated stream', () async {
    answer('data: [DONE]\n');
    final stream = await start();

    expect(await stream.toList(), isEmpty);
    expect((await stream.done)?.code, 'network_error');
  });

  test('malformed JSON frame carries the clean stream request id', () async {
    answer(frame('not-json'), requestId: 'req_malformed');
    final stream = await start();

    expect(await stream.toList(), isEmpty);
    expect(stream.error?.code, 'network_error');
    expect(stream.error?.message, contains('not valid JSON'));
    expect(stream.error?.requestId, 'req_malformed');
    expect((await stream.done)?.requestId, 'req_malformed');
  });

  test('an event over 16 MiB ends as network_error', () async {
    final hugeWire = utf8.encode('data: ${'x' * (17 * 1024 * 1024)}\n\n');
    engine.next(Scripted(
        chunks: [hugeWire], headers: {'x-request-id': 'req_oversize'}));
    final stream = await start();

    expect(await stream.toList(), isEmpty);
    expect(stream.error?.code, 'network_error');
    expect(stream.error?.requestId, 'req_oversize');
    expect((await stream.done)?.code, 'network_error');
  });

  test('second listen throws and text after listen returns aborted', () async {
    answer('${frame(chunk('one'))}${frame('[DONE]')}');
    final stream = await start();
    final first = stream.toList();

    expect(() => stream.listen((_) {}), throwsStateError);
    final text = await stream.text();
    expect(text, isA<Err<String>>());
    expect((text as Err<String>).error.code, 'aborted');
    expect(await first, hasLength(1));
    expect(await stream.done, isNull);
  });

  test('text is memoised when it owns the first read', () async {
    answer('${frame(chunk('Hel'))}${frame(chunk('lo'))}${frame('[DONE]')}');
    final stream = await start();
    final first = stream.text();
    final second = stream.text();

    expect(identical(first, second), isTrue);
    expect((await first as Ok<String>).data, 'Hello');
    expect(await stream.done, isNull);
  });

  test('cancel before listen yields no chunks and aborted end', () async {
    engine.next(const Scripted(chunks: [], hang: true));
    final stream = await start();
    await stream.cancel();

    expect(stream.error?.code, 'aborted');
    expect((await stream.done)?.code, 'aborted');
    expect(await stream.toList(), isEmpty);
  });

  test('subscription cancellation propagates and emits no zone error',
      () async {
    final zoneErrors = <Object>[];
    await runZonedGuarded<Future<void>>(() async {
      engine.next(
          Scripted(chunks: [utf8.encode(frame(chunk('first')))], hang: true));
      final stream = await start();
      final first = Completer<void>();
      final sub = stream.listen((part) {
        expect(part.delta, 'first');
        first.complete();
      });

      await first.future;
      await sub.cancel();
      expect((await stream.done)?.code, 'aborted');
      expect(engine.upstreamCancels, greaterThan(0));
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => zoneErrors.add(error));
    expect(zoneErrors, isEmpty);
  });

  test('caller abort mid-stream ends aborted', () async {
    final abort = Completer<void>();
    engine.next(
        Scripted(chunks: [utf8.encode(frame(chunk('first')))], hang: true));
    final stream = await start(abortTrigger: abort.future);
    final first = Completer<void>();
    final chunks = <String>[];
    stream.listen((part) {
      chunks.add(part.delta);
      first.complete();
    });

    await first.future;
    abort.complete();
    expect((await stream.done)?.code, 'aborted');
    expect(chunks, ['first']);
  });

  test('refusal before first byte is an Err with HTTP 402', () async {
    engine.next(engineError('insufficient_credit'));

    final result = await client.chat.stream(prompt());
    expect(result, isA<Err<ChatStream>>());
    final error = (result as Err<ChatStream>).error;
    expect(error.code, 'insufficient_credit');
    expect(error.status, 402);
  });

  test('relay of engine-format wire returns exact bytes', () async {
    final wire = '${frame(chunk('one'))}${frame(usageChunk())}'
        '${frame('[DONE]')}';
    answer(wire);
    final stream = await start();

    final bytes =
        await stream.relay((_) => null).expand((part) => part).toList();
    expect(bytes, utf8.encode(wire));
    expect(await stream.done, isNull);
  });

  test('relay strips nested prices and unsafe request ids from success data',
      () async {
    final first = chunk('safe')
      ..['supplier_price'] = 12
      ..['request_id'] = 'bad\nheader'
      ..['metadata'] = {
        'keep': true,
        'nested': {
          'total_cost': 3,
          'request_id': 'bad\rheader',
          'safe': 'value',
        },
      };
    final finalUsage = usageChunk()
      ..['usage'] = {
        'prompt_tokens': 3,
        'completion_tokens': 2,
        'total_tokens': 5,
        'provider_cost': 4,
      };
    answer('${frame(first)}${frame(finalUsage)}${frame('[DONE]')}');
    final stream = await start();

    final wire = utf8.decode(
        await stream.relay((_) => null).expand((bytes) => bytes).toList());
    final decoder = SseDecoder();
    final events = decoder.add(utf8.encode(wire));
    expect(events, hasLength(3));
    expect(events.last, '[DONE]');
    expect(jsonDecode(events.first), {
      ...chunk('safe'),
      'metadata': {
        'keep': true,
        'nested': {'safe': 'value'},
      },
    });
    expect(jsonDecode(events[1]), usageChunk());
    expect(await stream.done, isNull);
  });

  test('relay turns truncation into a terminal error frame', () async {
    answer(frame(chunk('partial')));
    final stream = await start();

    final bytes =
        await stream.relay((_) => null).expand((part) => part).toList();
    final wire = utf8.decode(bytes);
    expect(wire, startsWith(frame(chunk('partial'))));
    expect(wire, contains('"code":"network_error"'));
    expect(wire, contains('data: '));
    expect((await stream.done)?.code, 'network_error');
  });

  test('relay replaces an engine error frame but retains the SDK error',
      () async {
    answer(frame(envelope('upstream_error')));
    final stream = await start();
    const replacement = MeridianError(
      code: 'service_unavailable',
      type: 'api_error',
      status: 503,
      message: 'A safe explanation.',
      retryable: false,
    );

    final wire = utf8.decode(
        await stream.relay((_) => replacement).expand((b) => b).toList());
    expect(wire, contains('"code":"service_unavailable"'));
    expect(wire, contains('A safe explanation.'));
    expect(wire, isNot(contains('upstream_error')));
    expect(stream.error?.code, 'upstream_error');
  });

  test('relay replaces an SDK-side truncated-stream error', () async {
    answer(frame(chunk('partial')));
    final stream = await start();
    const replacement = MeridianError(
      code: 'service_unavailable',
      type: 'api_error',
      status: 503,
      message: 'A safe explanation.',
      retryable: false,
    );

    final wire = utf8.decode(
        await stream.relay((_) => replacement).expand((b) => b).toList());
    expect(wire, contains('"code":"service_unavailable"'));
    expect(wire, isNot(contains('"code":"network_error"')));
    expect(stream.error?.code, 'network_error');
  });

  test('cancelling relay stops the upstream body', () async {
    engine.next(
        Scripted(chunks: [utf8.encode(frame(chunk('first')))], hang: true));
    final stream = await start();
    final first = Completer<void>();
    final sub = stream.relay((_) => null).listen((_) => first.complete());

    await first.future;
    await sub.cancel();
    expect((await stream.done)?.code, 'aborted');
    expect(engine.upstreamCancels, greaterThan(0));
  });

  test('pausing a chat listener pauses and resumes the HTTP body', () async {
    engine.next(
        Scripted(chunks: [utf8.encode(frame(chunk('first')))], hang: true));
    final stream = await start();
    final first = Completer<void>();
    final sub = stream.listen((_) => first.complete());

    await first.future;
    sub.pause();
    await Future<void>.delayed(Duration.zero);
    expect(engine.upstreamPauses, greaterThan(0));
    sub.resume();
    await Future<void>.delayed(Duration.zero);
    expect(engine.upstreamResumes, greaterThan(0));
    await sub.cancel();
  });
}
