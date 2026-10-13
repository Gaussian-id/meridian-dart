import 'package:meridian/src/clock.dart' as clock;
import 'package:meridian/src/env.dart' as env;
import 'package:test/test.dart';

/// Record requested sleeps and restore the clock after the current test.
List<Duration> recordSleeps() {
  final originalSleeper = clock.sleeper;
  final originalJitter = clock.jitterSource;
  final sleeps = <Duration>[];
  clock.sleeper = (duration) async => sleeps.add(duration);
  clock.jitterSource = () => 0;
  addTearDown(() {
    clock.sleeper = originalSleeper;
    clock.jitterSource = originalJitter;
  });
  return sleeps;
}

/// Supply a test-only environment map and restore the reader afterward.
void fakeEnv(Map<String, String> values) {
  final original = env.envReader;
  env.envReader = (name) => values[name];
  addTearDown(() => env.envReader = original);
}
