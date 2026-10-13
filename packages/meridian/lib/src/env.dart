import 'env_none.dart' if (dart.library.io) 'env_io.dart' as platform;

/// Reads one environment variable; tests may replace this function.
String? Function(String) envReader = platform.readEnvironment;
