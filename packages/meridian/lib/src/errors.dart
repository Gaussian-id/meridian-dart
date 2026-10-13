import 'dart:convert';

/// The engine's error codes in its declared order.
const engineErrorCodes = <String>[
  'invalid_request',
  'invalid_api_key',
  'key_revoked',
  'key_expired',
  'project_unavailable',
  'organisation_unavailable',
  'model_not_allowed',
  'byok_required',
  'project_host_mismatch',
  'model_not_found',
  'route_not_found',
  'method_not_allowed',
  'capability_unsupported',
  'body_too_large',
  'rate_limited',
  'insufficient_credit',
  'hard_limit_reached',
  'entitlement_missing',
  'idempotency_conflict',
  'upstream_unavailable',
  'upstream_error',
  'deadline_exceeded',
  'service_unavailable',
  'internal',
  'invalid_token',
  'permission_denied',
  'not_found',
  'conflict',
];

/// The engine's HTTP status for each error code.
const statusByCode = <String, int>{
  'invalid_request': 400,
  'capability_unsupported': 400,
  'invalid_api_key': 401,
  'key_revoked': 401,
  'key_expired': 401,
  'invalid_token': 401,
  'insufficient_credit': 402,
  'project_unavailable': 403,
  'organisation_unavailable': 403,
  'model_not_allowed': 403,
  'byok_required': 403,
  'project_host_mismatch': 403,
  'permission_denied': 403,
  'entitlement_missing': 403,
  'model_not_found': 404,
  'route_not_found': 404,
  'not_found': 404,
  'method_not_allowed': 405,
  'idempotency_conflict': 409,
  'conflict': 409,
  'body_too_large': 413,
  'rate_limited': 429,
  'hard_limit_reached': 429,
  'internal': 500,
  'upstream_unavailable': 502,
  'upstream_error': 502,
  'service_unavailable': 503,
  'deadline_exceeded': 504,
};

/// Codes for which an otherwise safe call may be retried.
const retryableCodes = <String>{
  'rate_limited',
  'upstream_unavailable',
  'service_unavailable',
  'deadline_exceeded',
  'network_error',
};

/// The five engine error types and the SDK's local error type.
const knownTypes = <String>{
  'invalid_request_error',
  'authentication_error',
  'permission_error',
  'rate_limit_error',
  'api_error',
  'client_error',
};

/// A typed engine or SDK failure.
final class MeridianError {
  /// Creates an error with its complete public state.
  const MeridianError({
    required this.code,
    required this.type,
    required this.status,
    required this.message,
    required this.retryable,
    this.requestId,
    this.retryAfter,
    this.engineCode,
  });

  /// A known engine code or one of the SDK's two local codes.
  final String code;

  /// An engine type or `client_error` for a local failure.
  final String type;

  /// The HTTP status, or zero when no HTTP response arrived.
  final int status;

  /// A human-readable explanation.
  final String message;

  /// Whether retrying the logical call could succeed.
  final bool retryable;

  /// A safe request identifier, when one was supplied.
  final String? requestId;

  /// The server's retry delay, when valid.
  final Duration? retryAfter;

  /// An unrecognised raw engine code, kept separately from [code].
  final String? engineCode;

  /// Returns a copy with selected fields replaced.
  MeridianError copyWith({
    String? code,
    String? type,
    int? status,
    String? message,
    bool? retryable,
    String? requestId,
    Duration? retryAfter,
    String? engineCode,
  }) =>
      MeridianError(
        code: code ?? this.code,
        type: type ?? this.type,
        status: status ?? this.status,
        message: message ?? this.message,
        retryable: retryable ?? this.retryable,
        requestId: requestId ?? this.requestId,
        retryAfter: retryAfter ?? this.retryAfter,
        engineCode: engineCode ?? this.engineCode,
      );
}

/// Creates an SDK-side failure.
MeridianError clientError(String code, String message,
        {int status = 0, String? requestId}) =>
    MeridianError(
      code: code,
      type: 'client_error',
      status: status,
      message: message,
      retryable: code == 'network_error',
      requestId: cleanRequestId(requestId),
    );

/// Creates a configuration refusal without sending a request.
MeridianError configError(String message) =>
    clientError('invalid_request', message);

/// Keeps request ids that are 1–255 printable ASCII characters.
String? cleanRequestId(String? id) {
  if (id == null || id.isEmpty || id.length > 255) return null;
  for (final unit in id.codeUnits) {
    if (unit < 0x20 || unit > 0x7e) return null;
  }
  return id;
}

/// Extracts a Meridian error object from decoded JSON.
Map<String, Object?>? parseEnvelope(Object? decoded) {
  if (decoded is! Map<String, dynamic>) return null;
  final raw = decoded['error'];
  if (raw is! Map<String, dynamic> ||
      raw['code'] is! String ||
      raw['message'] is! String ||
      (raw['code'] as String).isEmpty) {
    return null;
  }
  return Map<String, Object?>.from(raw);
}

/// Decodes the error object from a Meridian envelope.
MeridianError errorFromEnvelope(Map<String, Object?> env,
    {int? status, Duration? retryAfter, String? headerRequestId}) {
  // [1] Unknown codes retain their raw form while presenting as internal.
  final raw = env['code'] as String? ?? '';
  final known = statusByCode.containsKey(raw);
  final code = known ? raw : 'internal';
  final rawMessage = env['message'] as String? ?? '';
  final message = known ? rawMessage : '$rawMessage (engine code: $raw)';
  final rawType = env['type'];
  final type = !known || rawType is! String || !knownTypes.contains(rawType)
      ? 'api_error'
      : rawType;

  // [2] Stream frames use the code's status; HTTP replies retain the actual status.
  final resolvedStatus = status ?? statusByCode[code] ?? 0;
  final explicitNoRetry = env['retryable'] == false;
  final retryable = !explicitNoRetry &&
      (retryableCodes.contains(code) || (!known && resolvedStatus >= 500));
  final requestId = cleanRequestId(
          env['request_id'] is String ? env['request_id'] as String : null) ??
      cleanRequestId(headerRequestId);

  // [3] Preserve the raw code and retry delay for callers and the forwarding route.
  return MeridianError(
    code: code,
    type: type,
    status: resolvedStatus,
    message: message,
    retryable: retryable,
    requestId: requestId,
    retryAfter: retryAfter,
    engineCode: known ? null : raw,
  );
}

/// Decodes an HTTP error response, including non-Meridian responses.
MeridianError errorFromBody(int status, String? headerRequestId, String body,
    {Duration? retryAfter}) {
  // [1] Try the engine envelope before treating the body as an intermediary reply.
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    // A proxy or intermediary may answer with HTML or an empty body.
  }
  final envelope = parseEnvelope(decoded);
  if (envelope != null) {
    return errorFromEnvelope(envelope,
        status: status,
        retryAfter: retryAfter,
        headerRequestId: headerRequestId);
  }
  // [2] Preserve the actual HTTP status and safe header request id.
  return MeridianError(
    code: 'network_error',
    type: 'client_error',
    status: status,
    message: 'The engine answered HTTP $status without a Meridian error body.',
    retryable: status == 429 || status >= 500,
    requestId: cleanRequestId(headerRequestId),
    retryAfter: retryAfter,
  );
}

/// Encodes one error object for a Meridian-compatible wire envelope.
Map<String, Object?> wireError(MeridianError error) {
  final wire = <String, Object?>{
    'message': error.message,
    'type': error.type == 'client_error' ? 'api_error' : error.type,
    'code': error.code,
  };
  final id = cleanRequestId(error.requestId);
  if (id != null) wire['request_id'] = id;
  if (!error.retryable && retryableCodes.contains(error.code)) {
    wire['retryable'] = false;
  }
  return wire;
}
