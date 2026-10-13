import 'errors.dart';
import 'result.dart';

/// Expands route placeholders into safe, individually encoded path segments.
MeridianResult<String> route(String template, List<String> values) {
  var path = template;
  for (final value in values) {
    var decoded = value;
    try {
      decoded = Uri.decodeComponent(value);
    } on ArgumentError {
      // A malformed escape is treated as literal input and encoded below.
    }
    if (_unsafeSegment(value) || _unsafeSegment(decoded)) {
      return Err(configError('A resource id must not be empty, "." or "..".'));
    }
    if (!path.contains('{}')) {
      return Err(configError('The route has too many identifiers.'));
    }
    path = path.replaceFirst('{}', Uri.encodeComponent(value));
  }
  if (path.contains('{}')) {
    return Err(configError('The route needs another identifier.'));
  }
  return Ok(path);
}

bool _unsafeSegment(String value) =>
    value.isEmpty || value == '.' || value == '..';
