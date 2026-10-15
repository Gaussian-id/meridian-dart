import 'errors.dart';

/// Remove price, cost and unsafe request-id fields from decoded JSON.
Object? withoutPrices(Object? value) {
  if (value is List<Object?>) {
    return value.map(withoutPrices).toList();
  }
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (!_priced.hasMatch(entry.key) &&
            (entry.key.toLowerCase() != 'request_id' ||
                (entry.value is String &&
                    cleanRequestId(entry.value as String) != null)))
          entry.key: withoutPrices(entry.value),
    };
  }
  return value;
}

final _priced = RegExp('cost|price', caseSensitive: false);
