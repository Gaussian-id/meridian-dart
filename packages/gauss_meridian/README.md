# gauss_meridian

The official Dart SDK for Gauss Meridian: one API for many AI models, routed by Meridian.

**Status:** Public preview, v0.1.0; Dart 3.11 or later. The test suite runs against an in-memory fake engine.

For Flutter apps, use the companion package [`gauss_meridian_flutter`](https://pub.dev/packages/gauss_meridian_flutter), which calls your own backend route and never holds a key.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Three entry points](#three-entry-points)
- [Results and errors](#results-and-errors)
- [Streaming](#streaming)
- [Forwarding a browser's chat through your server](#forwarding-a-browsers-chat-through-your-server)
- [Admin client](#admin-client)
- [Retries and idempotency](#retries-and-idempotency)
- [Security notes](#security-notes)
- [Links](#links)

## Install

```sh
dart pub add gauss_meridian
```

The package's only dependencies are `http` and `shelf`.

## Quick start

Read the URL and the project key (`gmr_...`) from the environment, never from source code:

```sh
export MERIDIAN_URL="https://your-engine.example"   # the engine's public listener
export MERIDIAN_KEY="..."                           # a project key from your secret store
```

A chat call:

```dart
import 'package:gauss_meridian/gauss_meridian.dart';

Future<void> main() async {
  final client = Meridian(); // or Meridian(url: ..., key: ...)
  try {
    final result = await client.chat.create(
      ChatParams(messages: [ChatMessage.user('Hello')]),
    );
    switch (result) {
      case Ok<ChatCompletion>(:final data):
        print(data.text);
      case Err<ChatCompletion>(:final error):
        print('${error.code}: ${error.message} (${error.requestId})');
    }
  } finally {
    client.close();
  }
}
```

`client.models.list()` lists the models. Omit `model` to let Meridian choose (`meridian/auto`). To request a reasoning effort, use a model such as `meridian/auto:high`; the suffixes are `low`, `medium`, `high`, `xhigh` and `max`. The SDK passes model strings through without validating them.

A complete program is in [`example/main.dart`](example/main.dart).

## Three entry points

| Import | Use it for | Credential |
|---|---|---|
| `package:gauss_meridian/gauss_meridian.dart` | `Meridian`, the server client | a project key (`MERIDIAN_URL`, `MERIDIAN_KEY`) |
| `package:gauss_meridian/browser.dart` | `MeridianBrowser`, a keyless client for Dart web apps | none: it calls your backend route |
| `package:gauss_meridian/admin.dart` | `MeridianAdmin`, organisation, project and key provisioning | an integrator key (`MERIDIAN_ADMIN_URL`, `MERIDIAN_INTEGRATOR_KEY`) |

`package:gauss_meridian/shelf.dart` adds the [forwarding route](#forwarding-a-browsers-chat-through-your-server).

`Meridian` and `MeridianAdmin` refuse to run in a browser or a Flutter app: they return an `invalid_request` error without sending anything. `MeridianBrowser` requires an **absolute** route and sends no project key or authorization header.

## Results and errors

Every call returns a `MeridianResult<T>`: an `Ok<T>` with `data`, or an `Err<T>` with `error`. API, network and configuration failures are never thrown, so `switch` on the result.

`error` is a `MeridianError`:

| Field | Meaning |
|---|---|
| `code` | one of the engine's error codes (`engineErrorCodes`), or the SDK's own `network_error` and `aborted` |
| `type` | the engine's error type, or `client_error` for the SDK's own errors |
| `message` | a readable message |
| `status` | the HTTP status (0 when nothing was received) |
| `retryable` | whether trying again later may help |
| `requestId` | the engine's id for the request; give it to support with any question about a call |
| `retryAfter` | the response's `Retry-After`, when it sent a valid one |
| `engineCode` | set only when the engine sent a code this SDK does not know; `code` is then `internal` |

A completion's `usage` holds the three token counts only. No cost or price field leaves the SDK.

## Streaming

`chat.stream` returns `Ok<ChatStream>` as soon as the response headers arrive. A `ChatStream` is a single-use `Stream<ChatChunk>`: choose `await for`, `listen`, or `text()`.

```dart
import 'package:gauss_meridian/gauss_meridian.dart';

Future<String> streamedText(Meridian client) async {
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

`done` resolves to `null` only after the engine's `[DONE]`; otherwise it gives a typed error. To collect the text instead, `await stream.text()` returns `Ok<String>` or `Err<String>`. To stop early, `await stream.cancel()` aborts the upstream request and `done` then has code `aborted`.

## Forwarding a browser's chat through your server

A browser or a Flutter app must never hold the project key. It calls a route on your server, which checks the user and adds the key. `meridianForwardHandler` is that route as a Shelf `Handler`:

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

Mount it at `/api/meridian/chat`. In Dart Frog, wrap it with `fromShelfHandler(chatHandler)`.

- `authorize` runs first and must return `true` or a Shelf `Response`; any other value is denied. Authenticate the app user here, before the route spends your project's credit.
- `AllowRule` limits what the browser may choose. By default the route forwards `messages` and `temperature`, caps `max_tokens` at `defaultMaxTokensCap` (4096), ignores a browser-chosen model (Meridian chooses) and drops every other field. Allow more with `models`, `anyModel`, `maxTokensCap` and `options`.
- The route accepts JSON `POST` only, limits bodies to 8 MiB and nesting to 64 levels, and keeps SSE framing for streamed replies.
- Failures of your own credentials, unknown engine codes and SDK failures reach the browser as a generic 503, so account details stay on the server.
- Messages are forwarded as sent. If your app needs a fixed system prompt, add it on the server before this handler; never trust one from the browser.
- The SDK does not configure CORS. For a web client on another origin, handle `OPTIONS` before this handler, and allow `POST`, `content-type` and `idempotency-key`.

## Admin client

On a trusted server, `MeridianAdmin` covers the 24 integrator operations: organisations, projects, keys, provider credentials and models.

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

The issued secret appears in the create response **once**. Store it in a server-side secret store; later key listings contain metadata only. Admin responses drop every field whose name contains `price` or `cost`.

## Retries and idempotency

Each chat call gets a fresh UUID idempotency key, or uses the `idempotencyKey:` you pass, and its retries reuse it. By default the SDK makes up to two more attempts on retryable failures; pass `maxRetries: 0` to turn that off. A `Retry-After` above 30 seconds ends the call instead of waiting. Project creation and key issuance are not retried on transient failures, only on rate limits; organisation creation is retried only when `externalReference` is set.

## Security notes

- Keep project keys (`gmr_...`) and integrator keys (`gmi_...`) on the server, read from the environment or a secret store. Never put one in source code, a web bundle or an app.
- Browser and Flutter clients talk only to your own route; the route decides who may spend credit.
- Use HTTPS in production.
- Report vulnerabilities privately; see [SECURITY.md](https://github.com/Gaussian-id/meridian-dart/blob/main/SECURITY.md).

## Links

- Repository: <https://github.com/Gaussian-id/meridian-dart>
- Issues: <https://github.com/Gaussian-id/meridian-dart/issues>
- Flutter package: [`gauss_meridian_flutter`](https://pub.dev/packages/gauss_meridian_flutter)
- Licence: Apache-2.0
