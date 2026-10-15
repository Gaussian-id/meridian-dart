import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'config.dart';
import 'errors.dart';
import 'models.dart';
import 'result.dart';
import 'server_client.dart';
import 'stream.dart';

/// Checks whether a request may use the application's Meridian credit.
typedef Authorize = FutureOr<Object?> Function(Request request);

/// Builds a server client for one authorized request.
typedef ClientFactory = FutureOr<Meridian> Function(Request request);

/// Default maximum output tokens allowed by the forwarding route.
const defaultMaxTokensCap = 4096;

/// Maximum JSON request body size accepted by the forwarding route.
const maxForwardBodyBytes = 8 * 1024 * 1024;

/// Maximum nesting depth accepted by the forwarding route.
const maxForwardBodyDepth = 64;

/// Engine refusals about the application's own account and credit.
const Set<String> appCredentialCodes = {
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
};

/// Limits what a browser may choose in a forwarded chat call.
final class AllowRule {
  /// Creates an allowlist. The default leaves model selection to Meridian.
  const AllowRule({
    this.anyModel = false,
    this.models = const [],
    this.maxTokensCap = defaultMaxTokensCap,
    this.options = const [],
  });

  /// Whether a browser may name any model.
  final bool anyModel;

  /// Model names the browser may select when [anyModel] is false.
  final List<String> models;

  /// Maximum output tokens; nonpositive values use the default.
  final int maxTokensCap;

  /// Additional body fields allowed through, excluding SDK-owned fields.
  final List<String> options;
}

/// Replace app-credential, unknown-code and SDK failures with a generic 503.
MeridianError browserError(MeridianError error) {
  if (error.type != 'client_error' &&
      error.engineCode == null &&
      !appCredentialCodes.contains(error.code)) {
    return error;
  }
  return _unavailable(error.requestId);
}

MeridianError _unavailable([String? requestId]) => MeridianError(
  code: 'service_unavailable',
  type: 'api_error',
  status: 503,
  message: 'The service is temporarily unavailable.',
  retryable: false,
  requestId: cleanRequestId(requestId),
);

/// Build a Shelf route that checks authorization before spending credit.
Handler meridianForwardHandler({
  required Authorize authorize,
  required ClientFactory client,
  AllowRule allow = const AllowRule(),
}) {
  return (request) async {
    // [1] Reject unsafe methods and content types before reading credentials.
    if (request.method != 'POST') {
      return _errorResponse(
        _forwardError('method_not_allowed', 405, 'Use POST.'),
        extraHeaders: const {'allow': 'POST'},
      );
    }
    if (!_isJson(request.headers['content-type'])) {
      return _errorResponse(
        _forwardError('invalid_request', 415, 'The request must be JSON.'),
      );
    }

    // [2] Bound and replay the body for authorization and validation.
    final body = await _readBody(request);
    if (body is Err<Uint8List>) return _errorResponse(body.error);
    final bytes = (body as Ok<Uint8List>).data;
    final replay = request.change(body: bytes);
    Object? decision;
    try {
      decision = await authorize(replay);
    } on Object {
      return _errorResponse(
        _forwardError(
          'permission_denied',
          403,
          'Not allowed to use this route.',
        ),
      );
    }
    if (decision is Response) return decision;
    if (decision != true) {
      return _errorResponse(
        _forwardError(
          'permission_denied',
          403,
          'Not allowed to use this route.',
        ),
      );
    }

    // [3] Validate the JSON shape before constructing a per-request client.
    final decoded = _decodeBody(bytes);
    if (decoded is Err<Map<String, dynamic>>) {
      return _errorResponse(decoded.error);
    }
    final value = (decoded as Ok<Map<String, dynamic>>).data;
    final params = _allowed(value, allow);
    if (params == null) {
      return _errorResponse(
        _forwardError(
          'invalid_request',
          400,
          'messages must be a non-empty array of message objects.',
        ),
      );
    }
    Meridian server;
    try {
      server = await client(replay);
    } on Object {
      return _errorResponse(_unavailable());
    }
    final callerKey = request.headers['idempotency-key'];
    final key = callerKey != null && validIdempotencyKey(callerKey)
        ? callerKey
        : null;

    // [4] Stream by relay, or answer one buffered completion as JSON.
    if (value['stream'] == true) {
      final opened = await server.chat.stream(params, idempotencyKey: key);
      if (opened is Err<ChatStream>) {
        return _errorResponse(browserError(opened.error));
      }
      final stream = (opened as Ok<ChatStream>).data;
      return Response.ok(
        stream.relay((error) {
          final replacement = browserError(error);
          return identical(replacement, error) ? null : replacement;
        }),
        headers: {
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
          if (stream.requestId != null) 'x-request-id': stream.requestId!,
        },
        context: const {'shelf.io.buffer_output': false},
      );
    }
    final reply = await server.chat.create(params, idempotencyKey: key);
    if (reply is Err<ChatCompletion>) {
      return _errorResponse(browserError(reply.error));
    }
    final completion = (reply as Ok<ChatCompletion>).data;
    return Response.ok(
      jsonEncode(completion.toJson()),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        if (completion.requestId != null) 'x-request-id': completion.requestId!,
      },
    );
  };
}

bool _isJson(String? value) =>
    value != null &&
    RegExp(
      r'^\s*application/json\s*(;.*)?$',
      caseSensitive: false,
    ).hasMatch(value);

MeridianError _forwardError(String code, int status, String message) =>
    MeridianError(
      code: code,
      type: code == 'permission_denied'
          ? 'permission_error'
          : 'invalid_request_error',
      status: status,
      message: message,
      retryable: false,
    );

Future<MeridianResult<Uint8List>> _readBody(Request request) async {
  // [1] Accumulate no more than the configured cap, before authorization.
  final builder = BytesBuilder(copy: false);
  try {
    await for (final part in request.read()) {
      if (builder.length + part.length > maxForwardBodyBytes) {
        return Err(
          _forwardError(
            'body_too_large',
            413,
            'The request body is too large.',
          ),
        );
      }
      builder.add(part);
    }
  } on Object {
    return Err(
      _forwardError('invalid_request', 400, 'The body is unreadable.'),
    );
  }
  return Ok(builder.takeBytes());
}

MeridianResult<Map<String, dynamic>> _decodeBody(Uint8List bytes) {
  // [1] Reject invalid UTF-8 and malformed JSON as a browser input error.
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return Err(
      _forwardError('invalid_request', 400, 'The body must be a JSON object.'),
    );
  }
  if (decoded is! Map<String, dynamic> || !_withinDepth(decoded)) {
    return Err(
      _forwardError('invalid_request', 400, 'The body must be a JSON object.'),
    );
  }
  return Ok(decoded);
}

bool _withinDepth(Object? value) {
  // [1] Traverse iteratively so nesting validation does not use the call stack.
  final pending = <(Object?, int)>[(value, 1)];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depth > maxForwardBodyDepth) return false;
    if (node is Map) {
      for (final child in node.values) {
        if (child is Map || child is List) pending.add((child, depth + 1));
      }
    } else if (node is List) {
      for (final child in node) {
        if (child is Map || child is List) pending.add((child, depth + 1));
      }
    }
  }
  return true;
}

const _neverRaw = <String>{
  'messages',
  'model',
  'stream',
  'stream_options',
  'max_tokens',
  'max_completion_tokens',
  'temperature',
  'n',
};

ChatParams? _allowed(Map<String, dynamic> body, AllowRule rule) {
  // [1] Validate every message before considering optional browser fields.
  final rawMessages = body['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) return null;
  final messages = <ChatMessage>[];
  for (final raw in rawMessages) {
    final message = ChatMessage.fromJson(raw);
    if (message == null) return null;
    messages.add(message);
  }

  // [2] Apply numeric limits without allowing browser-owned stream controls.
  final cap = rule.maxTokensCap <= 0
      ? defaultMaxTokensCap
      : min(rule.maxTokensCap, 2147483647);
  final asked = body['max_tokens'];
  final maxTokens = asked is num && asked.isFinite
      ? min(cap, max(1, asked.toInt()))
      : cap;
  final requestedTemperature = body['temperature'];
  final temperature =
      requestedTemperature is num && requestedTemperature.isFinite
      ? requestedTemperature
      : null;
  final requestedModel = body['model'];
  final model =
      requestedModel is String &&
          (rule.anyModel || rule.models.contains(requestedModel))
      ? requestedModel
      : null;

  // [3] Copy only named extras, never the fields the handler owns.
  final extras = <String, Object?>{};
  for (final name in rule.options) {
    if (!_neverRaw.contains(name) && body.containsKey(name)) {
      extras[name] = body[name];
    }
  }
  return ChatParams(
    messages: messages,
    maxTokens: maxTokens,
    temperature: temperature,
    model: model,
    extra: extras,
  );
}

Response _errorResponse(
  MeridianError error, {
  Map<String, String> extraHeaders = const {},
}) {
  final headers = <String, String>{
    'content-type': 'application/json; charset=utf-8',
    ...extraHeaders,
  };
  final requestId = cleanRequestId(error.requestId);
  if (requestId != null) headers['x-request-id'] = requestId;
  if (error.code == 'rate_limited' && error.retryAfter != null) {
    final milliseconds = error.retryAfter!.inMilliseconds;
    if (milliseconds > 0) {
      headers['retry-after'] = ((milliseconds + 999) ~/ 1000).toString();
    }
  }
  return Response(
    error.status,
    headers: headers,
    body: jsonEncode({'error': wireError(error)}),
  );
}
