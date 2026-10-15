import 'dart:convert';

import 'package:gauss_meridian/src/sse.dart';
import 'package:test/test.dart';

void main() {
  test('CRLF and a four-byte character survive byte boundaries', () {
    final decoder = SseDecoder();
    final bytes = utf8.encode('data: {"text":"😀"}\r\n\r\n');
    final events = <String>[];
    for (final byte in bytes) {
      events.addAll(decoder.add([byte]));
    }
    events.addAll(decoder.close());
    expect(events, ['{"text":"😀"}']);
    expect(decoder.tooLarge, false);
  });

  test('data lines join across a CR boundary and other fields are ignored', () {
    final decoder = SseDecoder();
    final events = <String>[];
    events.addAll(decoder.add(utf8.encode(': comment\rdata: first\r')));
    events.addAll(decoder.add(utf8.encode('data: second\revent: chat\r\r')));
    events.addAll(decoder.close());
    expect(events, ['first\nsecond']);
  });

  test('unterminated DONE does not dispatch', () {
    final decoder = SseDecoder();
    expect(decoder.add(utf8.encode('data: [DONE]')), isEmpty);
    expect(decoder.close(), isEmpty);
  });

  test('one event beyond 16 MiB is rejected', () {
    final decoder = SseDecoder();
    final oversized = utf8.encode('data: ${'x' * (17 * 1024 * 1024)}\n\n');
    expect(decoder.add(oversized), isEmpty);
    expect(decoder.tooLarge, true);
  });

  test('the event bound counts UTF-8 bytes rather than text units', () {
    final decoder = SseDecoder();
    final part = utf8.encode('€' * 4096);
    decoder.add(utf8.encode('data: '));
    for (var i = 0; i < 1366; i++) {
      decoder.add(part);
    }
    expect(decoder.tooLarge, true);
  });

  test('a split CRLF counts both wire bytes at the event bound', () {
    final decoder = SseDecoder();
    decoder.add(utf8.encode('data: ${'x' * (maxEventBytes - 7)}\r'));
    expect(decoder.tooLarge, false);
    decoder.add(utf8.encode('\n'));
    expect(decoder.tooLarge, true);
  });
}
