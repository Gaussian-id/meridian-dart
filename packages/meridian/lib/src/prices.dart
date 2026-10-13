/// Remove price and cost fields from any decoded JSON value.
Object? withoutPrices(Object? value) {
  if (value is List<Object?>) {
    return value.map(withoutPrices).toList();
  }
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final entry in value.entries)
        if (!_priced.hasMatch(entry.key)) entry.key: withoutPrices(entry.value),
    };
  }
  return value;
}

final _priced = RegExp('cost|price', caseSensitive: false);
