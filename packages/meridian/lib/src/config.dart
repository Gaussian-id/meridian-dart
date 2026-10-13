/// The default time allowed for a response.
const defaultTimeout = Duration(seconds: 60);

/// The default number of retries after the first attempt.
const defaultMaxRetries = 2;

/// Returns a positive timeout, falling back to the default.
Duration saneTimeout(Duration? value) =>
    value != null && value > Duration.zero ? value : defaultTimeout;

/// Returns a nonnegative retry count, falling back to the default.
int saneRetries(int? value) => value != null && value >= 0
    ? (value > defaultMaxRetries ? defaultMaxRetries : value)
    : defaultMaxRetries;

/// Explains why an HTTP endpoint cannot be used, or returns null.
String? urlRefusal(String? url, String what) {
  final uri = Uri.tryParse(url ?? '');
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment) {
    return null;
  }
  return '$what must be an absolute http(s) URL.';
}

/// Explains why a key cannot be sent in a header, or returns null.
String? keyRefusal(String? key, String what) {
  if (key == null || key.isEmpty) return '$what is required.';
  if (!_visibleAscii(key)) {
    return '$what must contain only visible ASCII characters.';
  }
  return null;
}

/// Whether a caller's idempotency key is safe for the HTTP header.
bool validIdempotencyKey(String key) =>
    key.isNotEmpty && key.length <= 255 && _visibleAscii(key);

bool _visibleAscii(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x21 || unit > 0x7e) return false;
  }
  return true;
}
