# gauss_meridian_flutter

Gauss Meridian for Flutter: a keyless client that streams chat from your own backend route on Android, iOS, web and desktop.

**Status:** Public preview, v0.1.0; Dart 3.11 or later. The widget tests run against an in-memory fake engine.

The app never holds a Meridian key. It calls a route on your server, and the server, using the core package [`gauss_meridian`](https://pub.dev/packages/gauss_meridian), checks the user and adds the project key.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Streaming](#streaming)
- [The server-side forwarding route](#the-server-side-forwarding-route)
- [Admin](#admin)
- [Results and errors](#results-and-errors)
- [Security notes](#security-notes)
- [Links](#links)

## Install

```sh
flutter pub add gauss_meridian_flutter
```

## Quick start

```dart
import 'package:gauss_meridian_flutter/gauss_meridian_flutter.dart';

Future<String> ask(String question) async {
  final client = MeridianBrowser(
    route: 'https://app.example/api/meridian/chat',
  );
  try {
    final result = await client.chat.create(
      ChatParams(messages: [ChatMessage.user(question)]),
    );
    return switch (result) {
      Ok<ChatCompletion>(:final data) => data.text,
      Err<ChatCompletion>(:final error) => 'Error: ${error.message}',
    };
  } finally {
    client.close();
  }
}
```

`route` must be an **absolute** URL to your backend route; a relative route is refused without sending a request. `MeridianBrowser` sends no project key and no authorization header. If your route needs the user's session, put the app's own authentication in front of it on the server.

## Streaming

`chat.stream` returns `Ok<ChatStream>` once the response headers arrive. A `ChatStream` is a single-use `Stream<ChatChunk>`, so it works with `StreamBuilder` or `listen`. Each chunk carries one `delta`; keep the accumulated text in your widget's state:

```dart
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:gauss_meridian_flutter/gauss_meridian_flutter.dart';

class Reply extends StatefulWidget {
  const Reply({super.key, required this.stream});

  final ChatStream stream;

  @override
  State<Reply> createState() => _ReplyState();
}

class _ReplyState extends State<Reply> {
  late final StreamSubscription<ChatChunk> _subscription;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _subscription = widget.stream.listen(
      (chunk) => setState(() => _text += chunk.delta),
    );
  }

  @override
  void dispose() {
    _subscription.cancel(); // also aborts the upstream request
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_text);
}
```

`await stream.done` resolves to `null` after a complete reply, or to a typed error; after a cancel its code is `aborted`. `await stream.text()` collects the whole reply instead. Disposing a `StreamBuilder` that listens to the stream cancels it the same way.

A complete app is in [`example/lib/main.dart`](example/lib/main.dart).

## The server-side forwarding route

The route the app calls is yours. With a Dart backend, `package:gauss_meridian/shelf.dart` provides it as a Shelf handler:

```dart
import 'package:gauss_meridian/gauss_meridian.dart';
import 'package:gauss_meridian/shelf.dart';
import 'package:shelf/shelf.dart';

final Handler chatHandler = meridianForwardHandler(
  authorize: (request) => request.context['authorized'] == true
      ? true
      : Response.forbidden('Forbidden'),
  client: (_) => Meridian(), // MERIDIAN_URL and MERIDIAN_KEY on the server
  allow: const AllowRule(maxTokensCap: 1024),
);
```

`authorize` decides who may spend your project's credit, and `AllowRule` limits which fields the app may set. See the [`gauss_meridian` README](https://pub.dev/packages/gauss_meridian) for the full behaviour. The Python, Go and JavaScript Meridian SDKs offer the same route for other backends.

For Flutter web on another origin, configure CORS on your server: handle `OPTIONS`, and allow `POST`, `content-type` and `idempotency-key`. The SDK does not configure CORS.

## Admin

Provisioning (organisations, projects, keys) needs an integrator key and belongs on a server only. Use `MeridianAdmin` from `package:gauss_meridian/admin.dart` there. Inside a Flutter app, `Meridian` and `MeridianAdmin` refuse to run and return an `invalid_request` error without sending anything.

## Results and errors

Every call returns `Ok<T>` with `data` or `Err<T>` with `error`; nothing is thrown, so `switch` on the result. `error` is a `MeridianError` with `code`, `type`, `message`, `status`, `retryable` and `requestId`. Give the `requestId` to support with any question about a call.

Chat calls send an idempotency key and retry retryable failures up to twice by default; pass `maxRetries: 0` to `MeridianBrowser` to turn that off.

## Security notes

- Never put a Meridian key (`gmr_...` or `gmi_...`) in an app: anything shipped in an app can be extracted.
- Authenticate the user on your server before forwarding, and cap what the app may request with `AllowRule`.
- Use HTTPS in production. A plain-HTTP development backend needs Android cleartext access and an iOS App Transport Security exception; the SDK does not change those platform policies.
- Report vulnerabilities privately; see [SECURITY.md](https://github.com/Gaussian-id/meridian-dart/blob/main/SECURITY.md).

## Links

- Repository: <https://github.com/Gaussian-id/meridian-dart>
- Issues: <https://github.com/Gaussian-id/meridian-dart/issues>
- Core package: [`gauss_meridian`](https://pub.dev/packages/gauss_meridian)
- Licence: Apache-2.0
