import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'models.dart';
import 'prices.dart';
import 'result.dart';
import 'sse.dart';
import 'transport.dart';

/// One streamed chat delta with its price-free wire object.
final class ChatChunk {
  /// Creates a streamed chat delta.
  const ChatChunk(this.delta, this.raw);

  /// Text added by this chunk, or an empty string for a non-text delta.
  final String delta;

  /// The decoded chunk, excluding price and cost fields.
  final Map<String, Object?> raw;
}

final class _Event {
  const _Event(this.data, {this.chunk, this.engineError});

  final String data;
  final ChatChunk? chunk;
  final MeridianError? engineError;
}

/// A single-use chat stream with typed terminal state and usage.
final class ChatStream extends Stream<ChatChunk> {
  /// Takes ownership of an opened streaming HTTP response.
  ChatStream(Opened opened)
      : _opened = opened,
        requestId = opened.requestId {
    _events = StreamController<_Event>(
      onListen: _start,
      onPause: () => _upstream?.pause(),
      onResume: () => _upstream?.resume(),
      onCancel: () {
        if (!_terminal) return cancel();
      },
    );
    unawaited(opened.watch.ended.then((reason) {
      if (_terminal) return;
      _finish(_withRequestId(reason), stopUpstream: true);
    }));
  }

  final Opened _opened;
  final SseDecoder _decoder = SseDecoder();
  final Completer<MeridianError?> _done = Completer<MeridianError?>();
  late final StreamController<_Event> _events;
  StreamSubscription<List<int>>? _upstream;
  Future<MeridianResult<String>>? _textFuture;
  bool _claimed = false;
  bool _terminal = false;
  bool _engineEnd = false;

  /// The terminal error, if the stream did not finish with `[DONE]`.
  MeridianError? get error => _error;
  MeridianError? _error;

  /// Final usage supplied by the engine, limited to three token counts.
  TokenUsage? get usage => _usage;
  TokenUsage? _usage;

  /// Sanitized request id from the response header.
  final String? requestId;

  /// Resolves when the stream ends, with null only after `[DONE]`.
  Future<MeridianError?> get done => _done.future;

  void _claim() {
    if (_claimed) throw StateError('This stream was already read.');
    _claimed = true;
  }

  @override
  StreamSubscription<ChatChunk> listen(
    void Function(ChatChunk event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _claim();
    return _events.stream
        .where((event) => event.chunk != null)
        .map((event) => event.chunk!)
        .listen(onData,
            onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  /// Collect text once; repeated calls return the same result future.
  Future<MeridianResult<String>> text() {
    if (_textFuture != null) return _textFuture!;
    if (_claimed) {
      return Future.value(
          Err(clientError('aborted', 'This stream was already read.')));
    }
    return _textFuture = _collectText();
  }

  Future<MeridianResult<String>> _collectText() async {
    final buffer = StringBuffer();
    await for (final chunk in this) {
      buffer.write(chunk.delta);
    }
    return _error == null ? Ok(buffer.toString()) : Err(_error!);
  }

  /// Cancel the stream and its upstream HTTP body.
  Future<void> cancel() async {
    if (!_terminal) {
      _finish(
          clientError('aborted', 'The call was cancelled.',
              requestId: requestId),
          stopUpstream: true);
    }
    await _upstream?.cancel();
  }

  /// Re-encode events for the forwarding handler, replacing selected errors.
  Stream<List<int>> relay(
      MeridianError? Function(MeridianError) replace) async* {
    _claim();
    await for (final event in _events.stream) {
      var data = event.data;
      if (event.engineError case final engineError?) {
        final replacement = replace(engineError);
        if (replacement != null) {
          data = jsonEncode({'error': wireError(replacement)});
        }
      }
      yield utf8.encode(_frame(data));
    }
    // SDK-side ends have no incoming error event, so synthesize one.
    if (_error != null && !_engineEnd) {
      final replacement = replace(_error!) ?? _error!;
      yield utf8.encode(_frame(jsonEncode({'error': wireError(replacement)})));
    }
  }

  void _start() {
    if (_terminal) return;
    _upstream = _opened.response.stream.listen(
      _receive,
      onError: (Object _) => _finish(
        _withRequestId(_opened.watch.error ??
            clientError('network_error', 'The stream connection was lost.')),
        stopUpstream: true,
      ),
      onDone: () {
        if (_terminal) return;
        for (final data in _decoder.close()) {
          _receiveEvent(data);
          if (_terminal) return;
        }
        _finish(clientError('network_error', 'The stream ended without [DONE].',
            requestId: requestId));
      },
      cancelOnError: false,
    );
  }

  void _receive(List<int> bytes) {
    if (_terminal) return;
    for (final data in _decoder.add(bytes)) {
      _receiveEvent(data);
      if (_terminal) return;
    }
    if (_decoder.tooLarge) {
      _finish(
          clientError('network_error', 'The stream event was too large.',
              requestId: requestId),
          stopUpstream: true);
    }
  }

  void _receiveEvent(String data) {
    // [1] DONE is recognized only after the decoder dispatches a full event.
    if (data == '[DONE]') {
      _events.add(_Event(data));
      _finish(null, stopUpstream: true);
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      _malformed();
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _malformed();
      return;
    }

    // [2] An engine error frame is terminal but remains relayable as received.
    if (decoded.containsKey('error')) {
      final envelope = parseEnvelope(decoded);
      if (envelope == null) {
        _malformed();
        return;
      }
      final engineError =
          errorFromEnvelope(envelope, headerRequestId: requestId);
      _engineEnd = true;
      var relayData = data;
      final rawId = envelope['request_id'];
      if (envelope.containsKey('request_id') &&
          (rawId is! String || cleanRequestId(rawId) == null)) {
        final safeEnvelope = Map<String, Object?>.of(envelope)
          ..remove('request_id');
        relayData = jsonEncode({...decoded, 'error': safeEnvelope});
      }
      _events.add(_Event(relayData, engineError: engineError));
      _finish(engineError, stopUpstream: true);
      return;
    }

    // [3] Usage-only events update usage without producing a text chunk.
    final choices = decoded['choices'];
    if (choices is! List) {
      _malformed();
      return;
    }
    if (decoded['usage'] != null) {
      _usage = TokenUsage.fromJson(decoded['usage']);
      if (_usage == null) {
        _malformed();
        return;
      }
    }
    ChatChunk? chunk;
    if (choices.isNotEmpty) {
      final first = choices.first;
      if (first is! Map<String, dynamic> ||
          first['delta'] is! Map<String, dynamic>) {
        _malformed();
        return;
      }
      final delta = (first['delta'] as Map<String, dynamic>)['content'];
      if (delta != null && delta is! String) {
        _malformed();
        return;
      }
      chunk = ChatChunk(delta as String? ?? '',
          withoutPrices(decoded) as Map<String, Object?>);
    }
    _events.add(_Event(data, chunk: chunk));
  }

  void _malformed() => _finish(
        clientError('network_error', 'The stream event was not valid JSON.',
            requestId: requestId),
        stopUpstream: true,
      );

  MeridianError _withRequestId(MeridianError value) =>
      value.requestId == null && requestId != null
          ? value.copyWith(requestId: requestId)
          : value;

  void _finish(MeridianError? end, {bool stopUpstream = false}) {
    if (_terminal) return;
    _terminal = true;
    _error = end;
    if (stopUpstream) {
      if (end != null) _opened.watch.abort();
      final upstream = _upstream;
      if (upstream != null) unawaited(upstream.cancel());
    }
    _opened.watch.close();
    unawaited(_events.close());
    _done.complete(end);
  }
}

String _frame(String data) =>
    '${data.split('\n').map((line) => 'data: $line\n').join()}\n';
