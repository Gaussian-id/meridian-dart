import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A request received by [FakeEngine].
final class RecordedRequest {
  /// Creates a recorded request.
  const RecordedRequest(this.method, this.url, this.headers, this.body);

  /// The HTTP method.
  final String method;

  /// The request URL.
  final Uri url;

  /// The request headers.
  final Map<String, String> headers;

  /// The UTF-8 request body.
  final String body;
}

/// One scripted response from [FakeEngine].
final class Scripted {
  /// Creates a scripted response.
  const Scripted({
    this.status = 200,
    this.headers = const {},
    this.json,
    this.text,
    this.chunks,
    this.dropAfter,
    this.hang = false,
    this.headersNever = false,
    this.networkError = false,
  });

  /// The HTTP response status.
  final int status;

  /// The HTTP response headers.
  final Map<String, String> headers;

  /// A JSON response body.
  final Object? json;

  /// A plain text response body.
  final String? text;

  /// Separate asynchronous body chunks.
  final List<List<int>>? chunks;

  /// Inject a connection error before this chunk index.
  final int? dropAfter;

  /// Keep the response body open after the last chunk.
  final bool hang;

  /// Keep the request pending before response headers arrive.
  final bool headersNever;

  /// Fail before response headers arrive.
  final bool networkError;
}

/// An in-memory Meridian engine using an abort-aware streaming HTTP mock.
final class FakeEngine {
  /// The fake public listener URL.
  static const publicUrl = 'http://engine.test';

  /// The fake admin listener URL.
  static const adminUrl = 'http://admin.engine.test';

  /// A test-only project key built at runtime.
  final String projectKey = 'gmr_${'0' * 64}';

  /// A test-only integrator key built at runtime.
  final String integratorKey = 'gmi_${'1' * 64}';

  /// Requests seen by this fake engine.
  final List<RecordedRequest> requests = [];

  /// Number of upstream body subscriptions cancelled.
  int upstreamCancels = 0;

  /// Number of pauses observed by the fake response body.
  int upstreamPauses = 0;

  /// Number of resumes observed by the fake response body.
  int upstreamResumes = 0;

  /// Number of abort triggers observed.
  int aborts = 0;

  final List<Scripted> _answers = [];

  /// The injectable HTTP client.
  late final http.Client client = MockClient.streaming(_handle);

  /// Queue one or more responses, consumed in order.
  void next(Scripted answer, [Scripted? second, Scripted? third]) {
    _answers.add(answer);
    if (second != null) _answers.add(second);
    if (third != null) _answers.add(third);
  }

  /// Decode all recorded request bodies as JSON.
  List<Object?> bodies() => requests
      .map((request) => request.body.isEmpty ? null : jsonDecode(request.body))
      .toList();

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream requestBody,
  ) async {
    // [1] Record the outgoing request and select its scripted response.
    final body = await utf8.decoder.bind(requestBody).join();
    requests.add(
      RecordedRequest(
        request.method,
        request.url,
        Map<String, String>.of(request.headers),
        body,
      ),
    );
    final answer = _answers.isEmpty
        ? Scripted(json: completion())
        : _answers.removeAt(0);
    final abortTrigger = request is http.Abortable
        ? request.abortTrigger
        : null;
    var aborted = false;
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) {
          aborted = true;
          aborts++;
        }),
      );
    }

    // [2] Emulate a network failure or a request stalled before headers.
    if (answer.networkError) {
      throw http.ClientException('fake network failure', request.url);
    }
    if (answer.headersNever) {
      if (abortTrigger != null) await abortTrigger;
      throw http.RequestAbortedException(request.url);
    }
    if (aborted) throw http.RequestAbortedException(request.url);

    // [3] Emit body parts asynchronously so cancellation can interrupt them.
    final headers = Map<String, String>.of(answer.headers);
    final parts =
        answer.chunks ??
        <List<int>>[
          utf8.encode(
            answer.json != null ? jsonEncode(answer.json) : answer.text ?? '',
          ),
        ];
    if (answer.json != null) {
      headers.putIfAbsent('content-type', () => 'application/json');
    }
    if (answer.chunks != null) {
      headers.putIfAbsent('content-type', () => 'text/event-stream');
    }
    var cancelled = false;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        if (abortTrigger != null) {
          unawaited(
            abortTrigger.then((_) {
              if (cancelled || controller.isClosed) return;
              controller.addError(http.RequestAbortedException(request.url));
              unawaited(controller.close());
            }),
          );
        }
        unawaited(() async {
          for (var index = 0; index < parts.length; index++) {
            await Future<void>.delayed(Duration.zero);
            if (cancelled || controller.isClosed) return;
            if (answer.dropAfter != null && index >= answer.dropAfter!) {
              controller.addError(
                http.ClientException('connection dropped', request.url),
              );
              await controller.close();
              return;
            }
            controller.add(parts[index]);
          }
          if (cancelled || controller.isClosed || answer.hang) return;
          if (answer.dropAfter == parts.length) {
            controller.addError(
              http.ClientException('connection dropped', request.url),
            );
          }
          await controller.close();
        }());
      },
      onCancel: () {
        cancelled = true;
        upstreamCancels++;
      },
      onPause: () => upstreamPauses++,
      onResume: () => upstreamResumes++,
    );
    return http.StreamedResponse(
      controller.stream,
      answer.status,
      headers: headers,
      request: request,
    );
  }
}

/// Build an engine-shaped error envelope.
Map<String, Object?> envelope(String code, {String requestId = 'req_fake_1'}) =>
    {
      'error': {
        'message': 'fake $code',
        'type': _typeByCode[code] ?? 'api_error',
        'code': code,
        'request_id': requestId,
      },
    };

/// Build an engine-shaped error response.
Scripted engineError(String code, {Map<String, String> headers = const {}}) =>
    Scripted(
      status: _statusByCode[code] ?? 500,
      headers: {'x-request-id': 'req_fake_1', ...headers},
      json: envelope(code),
    );

/// Wrap JSON or a marker in one SSE frame.
String frame(Object value) =>
    'data: ${value is String ? value : jsonEncode(value)}\n\n';

/// Build one content chunk.
Map<String, Object?> chunk(
  String content, {
  String model = 'gemini-3.8-flash',
}) => {
  'id': 'chatcmpl-fake',
  'object': 'chat.completion.chunk',
  'created': 0,
  'model': model,
  'choices': [
    {
      'index': 0,
      'delta': {'content': content},
      'finish_reason': null,
    },
  ],
};

/// Build a final usage chunk.
Map<String, Object?> usageChunk({int prompt = 3, int completion = 2}) => {
  'id': 'chatcmpl-fake',
  'object': 'chat.completion.chunk',
  'created': 0,
  'model': 'gemini-3.8-flash',
  'choices': <Object?>[],
  'usage': {
    'prompt_tokens': prompt,
    'completion_tokens': completion,
    'total_tokens': prompt + completion,
  },
};

/// Build a buffered chat completion.
Map<String, Object?> completion({
  String content = 'hello',
  String model = 'gemini-3.8-flash',
  Map<String, Object?>? usage,
}) => {
  'id': 'chatcmpl-fake',
  'object': 'chat.completion',
  'created': 0,
  'model': model,
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': content},
      'finish_reason': 'stop',
    },
  ],
  'usage':
      usage ?? {'prompt_tokens': 3, 'completion_tokens': 1, 'total_tokens': 4},
};

const _statusByCode = <String, int>{
  'invalid_request': 400,
  'invalid_api_key': 401,
  'key_revoked': 401,
  'key_expired': 401,
  'invalid_token': 401,
  'insufficient_credit': 402,
  'permission_denied': 403,
  'model_not_allowed': 403,
  'project_unavailable': 403,
  'organisation_unavailable': 403,
  'byok_required': 403,
  'project_host_mismatch': 403,
  'entitlement_missing': 403,
  'not_found': 404,
  'model_not_found': 404,
  'route_not_found': 404,
  'method_not_allowed': 405,
  'idempotency_conflict': 409,
  'conflict': 409,
  'body_too_large': 413,
  'capability_unsupported': 400,
  'rate_limited': 429,
  'hard_limit_reached': 429,
  'internal': 500,
  'upstream_unavailable': 502,
  'upstream_error': 502,
  'service_unavailable': 503,
  'deadline_exceeded': 504,
};

const _typeByCode = <String, String>{
  'invalid_request': 'invalid_request_error',
  'invalid_api_key': 'authentication_error',
  'key_revoked': 'authentication_error',
  'key_expired': 'authentication_error',
  'insufficient_credit': 'rate_limit_error',
  'rate_limited': 'rate_limit_error',
  'hard_limit_reached': 'rate_limit_error',
  'permission_denied': 'permission_error',
  'model_not_allowed': 'permission_error',
  'project_unavailable': 'permission_error',
  'organisation_unavailable': 'permission_error',
  'byok_required': 'permission_error',
  'project_host_mismatch': 'permission_error',
  'entitlement_missing': 'permission_error',
  'not_found': 'invalid_request_error',
  'method_not_allowed': 'invalid_request_error',
};
