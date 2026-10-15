import 'package:http/http.dart' as http;

import 'chat.dart';
import 'config.dart';
import 'errors.dart';
import 'transport.dart';

/// The documented default path for an application's forwarding route.
const defaultRoutePath = '/api/meridian/chat';

/// A key-free client for an application's absolute forwarding endpoint.
final class MeridianBrowser {
  MeridianBrowser._(this._transport) : chat = ChatApi(_transport, path: '');

  /// Construct a client that sends chat calls to [route] itself.
  factory MeridianBrowser({
    required String route,
    Duration? timeout,
    int? maxRetries,
    http.Client? httpClient,
  }) {
    // [1] Refuse relative and empty routes before any HTTP call is sent.
    final refusal = urlRefusal(route, 'browser route');
    if (refusal != null) {
      return MeridianBrowser._(Transport.refused(configError(
        '$refusal For example: https://example.com/api/meridian/chat',
      )));
    }
    // [2] The route is the endpoint; no key or user agent is configured.
    return MeridianBrowser._(Transport(
      baseUrl: route,
      timeout: timeout,
      maxRetries: maxRetries,
      httpClient: httpClient,
    ));
  }

  final Transport _transport;

  /// Chat completion operations.
  final ChatApi chat;

  /// Close the underlying HTTP client.
  void close() => _transport.close();
}
