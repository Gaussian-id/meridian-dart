import 'errors.dart';

/// A successful value or a typed Meridian failure.
sealed class MeridianResult<T> {
  /// Creates a result variant.
  const MeridianResult();
}

/// A successful Meridian call.
final class Ok<T> extends MeridianResult<T> {
  /// Creates a successful result.
  const Ok(this.data);

  /// The returned value.
  final T data;
}

/// A failed Meridian call.
final class Err<T> extends MeridianResult<T> {
  /// Creates a failed result.
  const Err(this.error);

  /// The typed failure.
  final MeridianError error;
}
