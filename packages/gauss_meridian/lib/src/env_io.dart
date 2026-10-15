import 'dart:io';

/// Reads a variable on an IO platform.
String? readEnvironment(String name) => Platform.environment[name];
