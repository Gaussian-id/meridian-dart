import 'dart:async';
import 'dart:math';

/// Waits for a retry delay; tests may replace this function.
Future<void> Function(Duration) sleeper = Future<void>.delayed;

/// Produces retry jitter in [0, 1); tests may replace this function.
double Function() jitterSource = Random().nextDouble;
