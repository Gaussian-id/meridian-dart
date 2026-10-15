// ignore_for_file: avoid_print

import 'dart:io';

const _paidNames = <String>{
  'GAUSSMERIDIAN_GEMINI_API_KEY',
  'GAUSSMERIDIAN_OPENROUTER_API_KEY',
  'GAUSSMERIDIAN_OPENAI_API_KEY',
  'GAUSSMERIDIAN_ANTHROPIC_API_KEY',
  'GAUSSMERIDIAN_XAI_API_KEY',
  'GAUSSMERIDIAN_DEEPSEEK_API_KEY',
  'GAUSSMERIDIAN_MISTRAL_API_KEY',
  'GAUSSMERIDIAN_QWEN_API_KEY',
};

final _assignment = RegExp(
  r'^\s*(?:export\s+)?(GAUSSMERIDIAN_[A-Z]+_API_KEY)\s*[=:]\s*(.*)$',
  caseSensitive: false,
);
final _empty = RegExp(r'''^(?:""|'')?\s*(?:#.*)?$''');

/// Names of paid provider keys assigned nonempty values in dotenv text.
///
/// This function never returns values or arbitrary text from the env file.
List<String> paidKeysIn(String text) {
  final names = <String>[];
  for (final line in text.split(RegExp(r'\r\n|\n|\r'))) {
    if (line.trimLeft().startsWith('#')) continue;
    final match = _assignment.firstMatch(line);
    if (match == null || _empty.hasMatch(match[2]!.trim())) continue;
    final name = match[1]!.toUpperCase();
    if (_paidNames.contains(name) && !names.contains(name)) names.add(name);
  }
  return names;
}

/// Whether an HTTP URL points to one of the exact local loopback hostnames.
bool isLoopbackUrl(String value) {
  try {
    final url = Uri.parse(value);
    return (url.scheme == 'http' || url.scheme == 'https') &&
        url.hasAuthority &&
        url.userInfo.isEmpty &&
        !url.hasQuery &&
        !url.hasFragment &&
        const {'127.0.0.1', 'localhost', '::1'}.contains(url.host);
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// Whether [child] resolves to a path below, but not equal to, [parent].
bool isInside(String parent, String child) {
  try {
    final root = _resolvedPath(parent);
    final target = _resolvedPath(child);
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedTarget = Platform.isWindows ? target.toLowerCase() : target;
    return normalizedTarget.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  } on FileSystemException {
    return false;
  }
}

String _resolvedPath(String path) {
  // [1] Find the nearest existing ancestor, so a symlink cannot escape.
  var current = File(path).absolute.path;
  final missing = <String>[];
  while (FileSystemEntity.typeSync(current) == FileSystemEntityType.notFound) {
    final parent = Directory(current).parent.path;
    if (parent == current) throw const FileSystemException('No path ancestor');
    missing.add(
      current.substring(parent.length).replaceFirst(RegExp(r'^[\\/]'), ''),
    );
    current = parent;
  }
  final kind = FileSystemEntity.typeSync(current);
  var resolved = kind == FileSystemEntityType.directory
      ? Directory(current).resolveSymbolicLinksSync()
      : File(current).resolveSymbolicLinksSync();
  // [2] Reattach absent children and collapse their dot segments.
  for (final name in missing.reversed) {
    resolved = '$resolved${Platform.pathSeparator}$name';
  }
  return File.fromUri(
    Uri.file(resolved, windows: Platform.isWindows).normalizePath(),
  ).absolute.path;
}

void _refuse(String reason) {
  print('Contract run refused: $reason');
  exitCode = 1;
}

/// Performs only safety checks. Real-engine contract execution is deferred.
void main() {
  // [1] Read only the local runtime env file, after proving containment.
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    return _refuse('LOCALAPPDATA is unavailable.');
  }
  final runtime =
      '$localAppData${Platform.pathSeparator}Gaussian'
      '${Platform.pathSeparator}MeridianEngine';
  final envPath =
      Platform.environment['GAUSSMERIDIAN_ENV_FILE'] ??
      '$runtime${Platform.pathSeparator}meridian-engine.env';
  if (!isInside(runtime, envPath)) {
    return _refuse(
      'GAUSSMERIDIAN_ENV_FILE is outside the local runtime folder.',
    );
  }
  String text;
  try {
    text = File(envPath).readAsStringSync();
  } on FileSystemException {
    return _refuse('the engine env file cannot be read.');
  }
  final paid = paidKeysIn(text);
  if (paid.isNotEmpty) {
    return _refuse(
      '${paid.join(', ')} is set; contract runs never spend money.',
    );
  }

  // [2] Refuse remote endpoints without contacting any endpoint.
  for (final name in ['MERIDIAN_PUBLIC_URL', 'MERIDIAN_ADMIN_URL']) {
    final fallback = name == 'MERIDIAN_PUBLIC_URL'
        ? 'http://127.0.0.1:8180'
        : 'http://127.0.0.1:8181';
    if (!isLoopbackUrl(Platform.environment[name] ?? fallback)) {
      return _refuse('$name is not a loopback URL.');
    }
  }
  // [3] No real engine or paid-provider call exists in this command.
  _refuse('the real-engine contract run is deferred.');
}
