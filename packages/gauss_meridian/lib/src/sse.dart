import 'dart:convert';

/// Maximum size of one pending server-sent event.
const maxEventBytes = 16 * 1024 * 1024;

/// Incrementally decodes UTF-8 server-sent events into their data payloads.
final class SseDecoder {
  /// Starts an incremental decoder for one HTTP response body.
  SseDecoder() {
    _utf8 = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.fromStringSink(_decoded));
  }

  final StringBuffer _decoded = StringBuffer();
  final StringBuffer _line = StringBuffer();
  final List<String> _data = [];
  late final ByteConversionSink _utf8;
  int _pendingSize = 0;
  bool _afterHighSurrogate = false;
  bool _pendingCr = false;
  bool _closed = false;

  /// Whether an event exceeded the 16 MiB bound.
  bool get tooLarge => _tooLarge;
  bool _tooLarge = false;

  /// Add bytes and return fully terminated event payloads.
  List<String> add(List<int> bytes) {
    if (_closed || _tooLarge) return const [];
    // Limit the temporary decoded string even when HTTP delivers one huge chunk.
    final events = <String>[];
    for (var start = 0; start < bytes.length; start += 64 * 1024) {
      final end = start + 64 * 1024 < bytes.length
          ? start + 64 * 1024
          : bytes.length;
      _utf8.add(bytes.sublist(start, end));
      events.addAll(_consume(_decoded.toString()));
      _decoded.clear();
      if (_tooLarge) break;
    }
    return events;
  }

  /// Flush UTF-8 state without dispatching an unterminated event.
  List<String> close() {
    if (_closed || _tooLarge) return const [];
    _closed = true;
    _utf8.close();
    final events = _consume(_decoded.toString());
    _decoded.clear();
    if (_pendingCr) {
      _pendingCr = false;
      _endLine(events);
    }
    return events;
  }

  List<String> _consume(String text) {
    // [1] Delay a trailing CR until the next character disambiguates CRLF.
    final events = <String>[];
    for (final code in text.codeUnits) {
      if (_pendingCr) {
        _pendingCr = false;
        if (code == 0x0a) {
          _pendingSize += 1;
          if (_pendingSize > maxEventBytes) {
            _tooLarge = true;
            return events;
          }
          _endLine(events);
          continue;
        }
        _endLine(events);
      }
      // [2] Bound UTF-8 bytes, including ignored fields and line endings.
      _pendingSize += _utf8Width(code);
      if (_pendingSize > maxEventBytes) {
        _tooLarge = true;
        return events;
      }
      if (code == 0x0d) {
        _pendingCr = true;
      } else if (code == 0x0a) {
        _endLine(events);
      } else {
        _line.writeCharCode(code);
      }
    }
    return events;
  }

  int _utf8Width(int code) {
    if (code >= 0xd800 && code <= 0xdbff) {
      _afterHighSurrogate = true;
      return 4;
    }
    if (code >= 0xdc00 && code <= 0xdfff && _afterHighSurrogate) {
      _afterHighSurrogate = false;
      return 0;
    }
    _afterHighSurrogate = false;
    if (code <= 0x7f) return 1;
    if (code <= 0x7ff) return 2;
    return 3;
  }

  void _endLine(List<String> events) {
    final line = _line.toString();
    _line.clear();
    if (line.isEmpty) {
      if (_data.isNotEmpty) events.add(_data.join('\n'));
      _data.clear();
      _pendingSize = 0;
      return;
    }
    if (line == 'data') {
      _data.add('');
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      _data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
}
