import 'dart:math';

import 'config.dart';
import 'errors.dart';
import 'models.dart';
import 'result.dart';
import 'stream.dart';
import 'transport.dart';

/// Chat completions through the shared Meridian transport.
final class ChatApi {
  /// Creates the chat interface for an endpoint.
  const ChatApi(this._transport, {String path = '/v1/chat/completions'})
      : _path = path;

  final Transport _transport;
  final String _path;

  /// Create one buffered chat completion.
  Future<MeridianResult<ChatCompletion>> create(
    ChatParams params, {
    String? idempotencyKey,
    Future<void>? abortTrigger,
  }) async {
    // [1] Validate a caller key before constructing or sending a request.
    if (idempotencyKey != null && !validIdempotencyKey(idempotencyKey)) {
      return Err(configError('The idempotency key is invalid.'));
    }
    final key = idempotencyKey ?? newIdempotencyKey();
    final call = Call.json(
      method: 'POST',
      path: _path,
      body: chatBody(params, stream: false),
      headers: {'idempotency-key': key},
    );
    // [2] Parse the public completion shape and keep the safe request id.
    final reply = await _transport.json(call, abortTrigger: abortTrigger);
    if (reply is Err<JsonReply>) return Err(reply.error);
    final value = (reply as Ok<JsonReply>).data;
    final completion =
        ChatCompletion.fromJson(value.value, requestId: value.requestId);
    if (completion == null) {
      return Err(clientError(
          'network_error', 'The chat response did not have the expected shape.',
          requestId: value.requestId));
    }
    return Ok(completion);
  }

  /// Open a streamed chat completion before reading its first body event.
  Future<MeridianResult<ChatStream>> stream(
    ChatParams params, {
    String? idempotencyKey,
    Future<void>? abortTrigger,
  }) async {
    if (idempotencyKey != null && !validIdempotencyKey(idempotencyKey)) {
      return Err(configError('The idempotency key is invalid.'));
    }
    final call = Call.json(
      method: 'POST',
      path: _path,
      body: chatBody(params, stream: true),
      headers: {'idempotency-key': idempotencyKey ?? newIdempotencyKey()},
    );
    final opened = await _transport.open(call, abortTrigger: abortTrigger);
    return switch (opened) {
      Ok<Opened>(:final data) => Ok(ChatStream(data)),
      Err<Opened>(:final error) => Err(error),
    };
  }
}

/// Model catalogue operations through the shared transport.
final class ModelsApi {
  /// Creates the model catalogue interface.
  const ModelsApi(this._transport);

  final Transport _transport;

  /// List models available to the project key.
  Future<MeridianResult<ModelList>> list() async {
    final reply =
        await _transport.json(const Call(method: 'GET', path: '/v1/models'));
    if (reply is Err<JsonReply>) return Err(reply.error);
    final value = (reply as Ok<JsonReply>).data;
    final models = ModelList.fromJson(value.value);
    if (models == null) {
      return Err(clientError(
          'network_error', 'The model list did not have the expected shape.',
          requestId: value.requestId));
    }
    return Ok(models);
  }
}

/// Build the chat wire body, overriding caller stream controls.
Map<String, Object?> chatBody(ChatParams params, {required bool stream}) {
  final body = Map<String, Object?>.of(params.toJson());
  body.remove('stream');
  body.remove('stream_options');
  body['stream'] = stream;
  if (stream) {
    body['stream_options'] = {'include_usage': true};
  }
  return body;
}

/// Create a random UUID v4 idempotency key for one logical chat call.
String newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
