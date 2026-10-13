import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'errors.dart';
import 'result.dart';

/// One HTTP call to an engine endpoint.
final class Call {
  /// Creates a call without a JSON body.
  const Call({
    required this.method,
    required this.path,
    this.query = const {},
    this.headers = const {},
    this.retry = true,
  })  : body = null,
        hasBody = false;

  /// Creates a call with a JSON-encoded body.
  const Call.json({
    required this.method,
    required this.path,
    required this.body,
    this.query = const {},
    this.headers = const {},
    this.retry = true,
  }) : hasBody = true;

  /// The HTTP method.
  final String method;

  /// The route relative to the configured endpoint.
  final String path;

  /// URL query parameters.
  final Map<String, String> query;

  /// The value to JSON-encode, when [hasBody] is true.
  final Object? body;

  /// Whether this call has a JSON body.
  final bool hasBody;

  /// Extra request headers.
  final Map<String, String> headers;

  /// Whether this call may be retried once retry support is enabled.
  final bool retry;
}

/// Controls the active request's timeout and caller cancellation.
final class AttemptWatch {
  /// Starts a watch for one attempt.
  AttemptWatch(Duration timeout, Future<void>? caller) {
    // [1] Turn the deadline into a typed network error.
    _timer = Timer(timeout, () {
      _end(clientError(
        'network_error',
        'No response within ${timeout.inSeconds} s.',
      ));
    });
    // [2] Observe caller cancellation without introducing an error future.
    if (caller != null) {
      unawaited(caller.then((_) => abort(), onError: (Object _) => abort()));
    }
  }

  final Completer<void> _abort = Completer<void>();
  final Completer<MeridianError> _endState = Completer<MeridianError>();
  late final Timer _timer;
  bool _closed = false;

  /// A trigger accepted by `http.AbortableRequest`.
  Future<void> get abortTrigger => _abort.future;

  /// The typed reason that ended this attempt early.
  Future<MeridianError> get ended => _endState.future;

  /// The known terminal error, when there is one.
  MeridianError? get error => _endState.isCompleted ? _error : null;
  MeridianError? _error;

  void _end(MeridianError error) {
    if (_closed || _endState.isCompleted) return;
    _error = error;
    _timer.cancel();
    _endState.complete(error);
    if (!_abort.isCompleted) _abort.complete();
  }

  /// Abort the active request or body stream.
  void abort() => _end(clientError('aborted', 'The call was cancelled.'));

  /// End the header deadline while a successful stream remains open.
  void stopTimeout() => _timer.cancel();

  /// Release the timer when the response is fully consumed.
  void close() {
    _closed = true;
    _timer.cancel();
  }
}

/// A response whose headers have arrived and whose body remains a stream.
final class Opened {
  /// Creates an open response.
  const Opened(this.response, this.requestId, this.watch);

  /// The HTTP response.
  final http.StreamedResponse response;

  /// A safe engine request id, if supplied.
  final String? requestId;

  /// The attempt's abort and timeout watch.
  final AttemptWatch watch;
}

/// A decoded JSON response and its safe request id.
final class JsonReply {
  /// Creates a decoded reply.
  const JsonReply(this.value, this.requestId);

  /// The decoded JSON value, or null for HTTP 204.
  final Object? value;

  /// A safe engine request id, if supplied.
  final String? requestId;
}

/// Shared HTTP transport for server, browser and admin clients.
final class Transport {
  /// Creates a transport for one base URL.
  Transport({
    required String baseUrl,
    String? key,
    Duration? timeout,
    int? maxRetries,
    http.Client? httpClient,
    String? userAgent,
  })  : _baseUrl = baseUrl,
        _key = key,
        _timeout = saneTimeout(timeout),
        _maxRetries = saneRetries(maxRetries),
        _client = httpClient ?? http.Client(),
        _userAgent = userAgent,
        _refusal = null;

  /// Creates a transport that returns the same configuration refusal.
  Transport.refused(MeridianError error)
      : _baseUrl = '',
        _key = null,
        _timeout = defaultTimeout,
        _maxRetries = defaultMaxRetries,
        _client = http.Client(),
        _userAgent = null,
        _refusal = error;

  final String _baseUrl;
  final String? _key;
  final Duration _timeout;
  final int _maxRetries;
  final http.Client _client;
  final String? _userAgent;
  final MeridianError? _refusal;
  bool _closed = false;

  /// Maximum additional attempts configured for this transport.
  int get maxRetries => _maxRetries;

  /// Open a response, resolving errors before returning its body stream.
  Future<MeridianResult<Opened>> open(
    Call call, {
    Future<void>? abortTrigger,
  }) async {
    // [1] Reject configuration and unencodable bodies before sending.
    if (_refusal != null) return Err(_refusal);
    if (_closed) return Err(configError('This client is closed.'));
    String? body;
    if (call.hasBody) {
      try {
        body = jsonEncode(call.body);
      } on Object {
        return Err(configError('The request body is not valid JSON.'));
      }
    }
    final base = Uri.parse(_baseUrl);
    final resolved = base.resolve(call.path);
    final url = call.query.isEmpty
        ? resolved
        : resolved.replace(queryParameters: {
            ...resolved.queryParameters,
            ...call.query,
          });
    final watch = AttemptWatch(_timeout, abortTrigger);
    final request = http.AbortableRequest(
      call.method,
      url,
      abortTrigger: watch.abortTrigger,
    );
    request.headers.addAll(call.headers);
    if (_key != null) request.headers['authorization'] = 'Bearer $_key';
    if (_userAgent != null) request.headers['user-agent'] = _userAgent;
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = body;
    }

    // [2] Race the client against the watch, including clients that ignore aborts.
    final sent = _client
        .send(request)
        .then<MeridianResult<http.StreamedResponse>>(
          (response) => Ok(response),
          onError: (Object error, StackTrace _) => Err<http.StreamedResponse>(
            watch.error ?? clientError('network_error', 'The request failed.'),
          ),
        );
    final outcome = await Future.any<MeridianResult<http.StreamedResponse>>([
      sent,
      watch.ended.then((error) => Err(error)),
    ]);
    if (outcome is Err<http.StreamedResponse>) {
      watch.close();
      return Err(outcome.error);
    }
    final response = (outcome as Ok<http.StreamedResponse>).data;
    final requestId = cleanRequestId(_header(response.headers, 'x-request-id'));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Ok(Opened(response, requestId, watch));
    }

    // [3] Read failed replies through the same watched body path.
    final text = await _readBody(response.stream, watch, requestId);
    watch.close();
    if (text is Err<String>) return Err(text.error);
    return Err(errorFromBody(
      response.statusCode,
      requestId,
      (text as Ok<String>).data,
    ));
  }

  /// Return a JSON reply, with HTTP and decode failures as typed errors.
  Future<MeridianResult<JsonReply>> json(
    Call call, {
    Future<void>? abortTrigger,
  }) async {
    // [1] Open the response and preserve its watch through body consumption.
    final opened = await open(call, abortTrigger: abortTrigger);
    if (opened is Err<Opened>) return Err(opened.error);
    final value = (opened as Ok<Opened>).data;
    final body =
        await _readBody(value.response.stream, value.watch, value.requestId);
    value.watch.close();
    if (body is Err<String>) return Err(body.error);
    if (value.response.statusCode == 204) {
      return Ok(JsonReply(null, value.requestId));
    }

    // [2] A success status with an error envelope is still an error.
    final text = (body as Ok<String>).data;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return Err(clientError(
        'network_error',
        'The response was not valid JSON.',
        status: value.response.statusCode,
        requestId: value.requestId,
      ));
    }
    if (decoded is Map<String, Object?> && decoded.containsKey('error')) {
      return Err(errorFromBody(
        value.response.statusCode,
        value.requestId,
        text,
      ));
    }
    return Ok(JsonReply(decoded, value.requestId));
  }

  /// Close the underlying HTTP client.
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

Future<MeridianResult<String>> _readBody(
  Stream<List<int>> stream,
  AttemptWatch watch,
  String? requestId,
) async {
  // [1] Convert the byte stream while consuming stream errors as typed results.
  final read = utf8.decoder.bind(stream).join().then<MeridianResult<String>>(
        (text) => Ok(text),
        onError: (Object error, StackTrace _) => Err<String>(
          watch.error ??
              clientError('network_error', 'The response body was interrupted.',
                  requestId: requestId),
        ),
      );
  // [2] Keep a noncooperative client from holding the call past its deadline.
  return Future.any<MeridianResult<String>>([
    read,
    watch.ended.then((error) => Err(error)),
  ]);
}

String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}
