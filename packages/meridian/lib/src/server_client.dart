import 'package:http/http.dart' as http;

import 'chat.dart';
import 'config.dart';
import 'env.dart';
import 'errors.dart';
import 'runtime.dart';
import 'transport.dart';
import 'version.dart';

/// Server-side Meridian client authenticated with a project key.
final class Meridian {
  Meridian._(this._transport)
      : chat = ChatApi(_transport),
        models = ModelsApi(_transport);

  /// Construct a server client from explicit options or environment values.
  factory Meridian({
    String? url,
    String? key,
    Duration? timeout,
    int? maxRetries,
    http.Client? httpClient,
  }) {
    // [1] Refuse unsafe runtimes before looking up configuration.
    if (serverRuntimeRefusal != null) {
      return Meridian._(Transport.refused(configError(serverRuntimeRefusal!)));
    }
    final endpoint = url ?? envReader('MERIDIAN_URL');
    final credential = key ?? envReader('MERIDIAN_KEY');
    // [2] Reject invalid configuration without sending a request.
    final urlError = urlRefusal(endpoint, 'server URL');
    if (urlError != null) {
      return Meridian._(Transport.refused(configError(urlError)));
    }
    final keyError = keyRefusal(credential, 'project key');
    if (keyError != null) {
      return Meridian._(Transport.refused(configError(keyError)));
    }
    // [3] Share one transport across public operation groups.
    return Meridian._(Transport(
      baseUrl: endpoint!,
      key: credential,
      timeout: timeout,
      maxRetries: maxRetries,
      httpClient: httpClient,
      userAgent: 'meridian-dart/$meridianVersion',
    ));
  }

  final Transport _transport;

  /// Chat completion operations.
  final ChatApi chat;

  /// Model catalogue operations.
  final ModelsApi models;

  /// Close the underlying HTTP client.
  void close() => _transport.close();
}
