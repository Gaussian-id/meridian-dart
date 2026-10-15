# Changelog

## 0.1.0

First public preview.

- Engine API `2.0.0-alpha.0`, from engine spec revision `563a0f673e1b`, through `gauss_meridian` 0.1.0.
- Exports `MeridianBrowser` and the chat types from `gauss_meridian`: a keyless client that streams chat from your own backend route on Android, iOS, web and desktop.
- A `ChatStream` works with `StreamBuilder`; disposing the widget cancels the upstream request.
