# Meridian Dart SDK

Private development repository for the `meridian` Dart SDK and its `meridian_flutter` companion. Both packages are unpublished. Use the server client with a project key, and the browser or Flutter client through your own backend route without a key.

## Install

Until publication, add a path dependency from an app beside this checkout:

```yaml
# Dart server pubspec.yaml
dependencies:
  gauss_meridian:
    path: ../meridian-dart/packages/gauss_meridian
```

```yaml
# Flutter app pubspec.yaml
dependencies:
  gauss_meridian_flutter:
    path: ../meridian-dart/packages/gauss_meridian_flutter
```

Run `dart pub get` or `flutter pub get` in the corresponding app; adjust the path if needed. After owner decision O47 and publication, use `dart pub add meridian` or `flutter pub add meridian_flutter`. Those pub.dev commands cannot be verified until publication.

## Three entry points

On a Dart server, import `package:gauss_meridian/gauss_meridian.dart`. Set `MERIDIAN_URL` and `MERIDIAN_KEY` in the server environment, or pass `url:` and `key:` to `Meridian`. Keep the project key off client devices.

```dart
import 'package:gauss_meridian/gauss_meridian.dart';

Future<String> serverExample() async {
  final client = Meridian();
  try {
    final result = await client.chat.create(
      ChatParams(messages: [ChatMessage.user('Hello')]),
    );
    return switch (result) {
      Ok<ChatCompletion>(:final data) => data.text,
      Err<ChatCompletion>(:final error) => throw StateError(error.message),
    };
  } finally {
    client.close();
  }
}
```

For a browser, import `package:gauss_meridian/browser.dart`. `MeridianBrowser` requires an **absolute** backend route and sends no project key or authorization header. For Flutter, change the import below to `package:gauss_meridian_flutter/gauss_meridian_flutter.dart`; that entry point exports the same browser client and chat types.

```dart
import 'package:gauss_meridian/browser.dart';

Future<String> browserExample() async {
  final client = MeridianBrowser(
    route: 'https://app.example/api/meridian/chat',
  );
  try {
    final result = await client.chat.create(
      ChatParams(messages: [ChatMessage.user('Hello')]),
    );
    return switch (result) {
      Ok<ChatCompletion>(:final data) => data.text,
      Err<ChatCompletion>(:final error) => throw StateError(error.message),
    };
  } finally {
    client.close();
  }
}
```

On a trusted server, import `package:gauss_meridian/admin.dart`. Set `MERIDIAN_ADMIN_URL` and `MERIDIAN_INTEGRATOR_KEY`, or pass `url:` and `key:` to `MeridianAdmin`. It implements the 24 pinned integrator operations. Keep this key-issuance function on the backend and persist the issued secret before returning to an app user.

```dart
import 'package:gauss_meridian/admin.dart';

Future<void> issueProjectKey(
  String orgId,
  String projectId,
  Future<void> Function(String secret) storeSecret,
) async {
  final admin = MeridianAdmin();
  try {
    final result = await admin.keys.create(
      orgId,
      projectId,
      const IssueKey(name: 'App backend'),
    );
    final secret = switch (result) {
      Ok<IssuedKey>(:final data) => data.apiKey,
      Err<IssuedKey>(:final error) => throw StateError(error.message),
    };
    await storeSecret(secret);
  } finally {
    admin.close();
  }
}
```

The issued secret appears in the create response **once**. Store it in a server-side secret store; later key listings contain metadata only. Admin responses remove fields whose names contain `price` or `cost`, including nested routing-record fields.

## Model choice and streaming

Omit `model` to let Meridian choose (`meridian/auto`). For a specific effort level, use a model such as `meridian/auto:high`. The exact suffixes are `low`, `medium`, `high`, `xhigh`, and `max`. The engine rejects an extra colon or another suffix; the SDK passes model strings through without validating them.

`chat.stream` returns `Ok<ChatStream>` when response headers arrive. Each stream is single-use: choose `await for`, `text()`, or `StreamBuilder`. `done` resolves to `null` only after `[DONE]`; otherwise it returns a typed error. `cancel()` aborts upstream.

```dart
import 'package:gauss_meridian/browser.dart';

Future<String> streamedText(MeridianBrowser client) async {
  final opened = await client.chat.stream(
    ChatParams(
      messages: [ChatMessage.user('Hello')],
      model: 'meridian/auto:high',
    ),
  );
  switch (opened) {
    case Err<ChatStream>(:final error):
      throw StateError(error.message);
    case Ok<ChatStream>(:final data):
      final buffer = StringBuffer();
      await for (final chunk in data) {
        buffer.write(chunk.delta);
      }
      final end = await data.done;
      if (end != null) throw StateError(end.message);
      return buffer.toString();
  }
}
```

To collect text instead, call `await stream.text()` and switch on `Ok<String>` or `Err<String>`. To stop early, call `await stream.cancel()`; `await stream.done` then has code `aborted`. In Flutter, `StreamBuilder<ChatChunk>(stream: stream, builder: (context, snapshot) => Text(snapshot.data?.delta ?? ''))` displays each delta. Keep accumulated text in widget state if you need the entire answer. Disposing the widget cancels its subscription and upstream stream.

## Forward through your backend

`package:gauss_meridian/shelf.dart` provides a Shelf handler. Authenticate the app user before spending the server's project credit. `authorize` must return `true` or a Shelf `Response`; other values are denied. This example expects upstream authentication middleware to set `request.context['authorized']`:

```dart
import 'package:gauss_meridian/gauss_meridian.dart';
import 'package:gauss_meridian/shelf.dart';
import 'package:shelf/shelf.dart';

final Handler chatHandler = meridianForwardHandler(
  authorize: (request) => request.context['authorized'] == true
      ? true
      : Response.forbidden('Forbidden'),
  client: (_) => Meridian(),
  allow: const AllowRule(maxTokensCap: 1024),
);
```

Mount this at `/api/meridian/chat`. In a Dart Frog route, adapt the same Shelf handler:

```dart
import 'package:dart_frog/dart_frog.dart';
import 'package:your_app/meridian_handler.dart' show chatHandler;

final onRequest = fromShelfHandler(chatHandler);
```

Make sure the app's authentication context reaches `authorize`. The route accepts JSON `POST` requests only, limits bodies to 8 MiB and nesting to 64, and restricts browser-selected fields through `AllowRule`. Messages are forwarded as supplied. If your app needs a fixed system prompt, prepend it **server-side** in bounded middleware before this handler; do not trust a browser-supplied prompt.

App-credential failures, unknown engine codes, and SDK failures become a generic 503, hiding backend account details. Permitted end-user errors remain visible; streamed replies retain SSE framing.

For Flutter web, configure CORS in your server/router for your app's trusted origin. Handle `OPTIONS` before the JSON-only handler; allow `POST`, `content-type`, and `idempotency-key`. Expose `x-request-id` if needed. The SDK does not configure CORS.

For a plain-HTTP development backend, configure Android cleartext access and an iOS App Transport Security development exception. The SDK does not change those platform policies. Use HTTPS in production.

## Retries and idempotency

Chat calls generate a fresh UUID idempotency key for each logical call, or accept `idempotencyKey:`. Retries reuse it. The default is two additional attempts on retryable failures; `maxRetries:` can reduce this to zero. A server `Retry-After` above 30 seconds ends the call without waiting. Project creation and key issuance skip transient retries, while rate limits remain eligible. Organisation creation retries transient failures only when `externalReference` is non-empty. Reuse your own stable idempotency key when replaying a chat call from app code.

## Direct API

This shell example uses placeholders for a separately configured public endpoint and project key:

```sh
curl --request POST "$MERIDIAN_URL/v1/chat/completions" \
  --header "Authorization: Bearer $MERIDIAN_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"Hello"}]}'
```

Run it only against a Meridian endpoint you control. No live-engine request is part of this SDK's verification.

## Project status

- This repository is private and both packages remain unpublished. The core `meridian` name is chosen; publication and the companion package name await owner decision O47.
- The guarded contract command is refusal-only in this development run; a real-engine contract run is deferred.
- Routing-record `record` data can contain supplier prices in the engine, but this SDK strips price and cost fields under D-27. Exposing them through an SDK requires a separate owner decision.
