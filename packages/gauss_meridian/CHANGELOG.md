# Changelog

## 0.1.0

First public preview.

- Engine API `2.0.0-alpha.0`, from engine spec revision `563a0f673e1b`.
- `Meridian`: the server chat client, with `chat.create`, `chat.stream` and `models.list`.
- `MeridianBrowser` (`package:gauss_meridian/browser.dart`): a keyless client that calls your own backend route.
- `MeridianAdmin` (`package:gauss_meridian/admin.dart`): the 24 integrator operations, with price and cost fields removed.
- `meridianForwardHandler` (`package:gauss_meridian/shelf.dart`): a Shelf route that authorizes the user, applies an `AllowRule` and forwards chat, streamed or not.
- Every call returns `Ok` or `Err` with a typed `MeridianError`; retries reuse one idempotency key.
