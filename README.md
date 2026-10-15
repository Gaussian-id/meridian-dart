# Meridian Dart SDK

The official Dart and Flutter SDKs for Gauss Meridian: one API for many AI models, routed by Meridian.

**Status:** Public preview, v0.1.0; Dart 3.11 or later.

| Package | Use it for | Install |
|---|---|---|
| [`gauss_meridian`](packages/gauss_meridian) | Dart servers: the chat client, streaming, admin provisioning and a Shelf forwarding route | `dart pub add gauss_meridian` |
| [`gauss_meridian_flutter`](packages/gauss_meridian_flutter) | Flutter apps on Android, iOS, web and desktop: a keyless client that calls your own backend route | `flutter pub add gauss_meridian_flutter` |

Each package's README has the quick start, streaming, the forwarding route, admin, errors and security notes:

- [packages/gauss_meridian/README.md](packages/gauss_meridian/README.md)
- [packages/gauss_meridian_flutter/README.md](packages/gauss_meridian_flutter/README.md)

`gauss_meridian_flutter` depends on the hosted `gauss_meridian`, so release `gauss_meridian` to pub.dev first, then `gauss_meridian_flutter`.

## How the pieces fit

1. **Your server** uses `Meridian` from `gauss_meridian` with a project key (`gmr_...`) read from the environment.
2. **Your app** (Flutter or Dart web) uses `MeridianBrowser`, which holds no key and calls a route on your server.
3. **The route** (`meridianForwardHandler` from `package:gauss_meridian/shelf.dart`) checks the user, limits what the app may request, and adds the key.

Provisioning with an integrator key (`gmi_...`) uses `MeridianAdmin` from `package:gauss_meridian/admin.dart`, on a server only.

## Direct API

The engine's API can also be called directly from a server, with the key from an environment variable:

```sh
curl --request POST "$MERIDIAN_URL/v1/chat/completions" \
  --header "Authorization: Bearer $MERIDIAN_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"Hello"}]}'
```

## Development

The core package's checks run from `packages/gauss_meridian`:

```sh
dart run tool/gates.dart
```

It runs formatting, `dart analyze --fatal-infos`, the tests and the generated-code check for the core package, then formatting, `flutter analyze --fatal-infos` and `flutter test` for the Flutter package. The Flutter package resolves the core from this checkout through `pubspec_overrides.yaml`.

`spec/` holds the pinned engine API description the generated admin models come from.

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
