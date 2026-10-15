// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

Future<List<int>> _git(Directory engine, List<String> arguments) async {
  final result = await Process.run(
      'git',
      [
        '-C',
        engine.path,
        ...arguments,
      ],
      stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.first} failed: ${result.stderr}');
  }
  return result.stdout as List<int>;
}

Future<void> main(List<String> args) async {
  // [1] Resolve the engine from the package working directory and read its
  // merged branch, never the engine working tree.
  final engine = Directory(args.isEmpty ? '../../../../1. Engine' : args[0]);
  final ref = args.length < 2 ? 'origin/meridian-2.0' : args[1];
  final spec = Directory('../../spec')..createSync(recursive: true);
  final documents = <String, Map<String, Object?>>{};
  for (final name in ['meridian-public.json', 'meridian-admin.json']) {
    final bytes = await _git(engine, ['show', '$ref:deploy/openapi/$name']);
    File('${spec.path}/$name').writeAsBytesSync(bytes);
    documents[name] = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  }

  // [2] Record the exact source revision and both document versions.
  final revision = utf8.decode(await _git(engine, ['rev-parse', ref])).trim();
  final now = DateTime.now();
  final date = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  String version(String name) =>
      (documents[name]!['info'] as Map<String, Object?>)['version'] as String;
  final source = {
    'engineCommit': revision.substring(0, 12),
    'engineRef': ref,
    'pinnedAt': date,
    'publicVersion': version('meridian-public.json'),
    'adminVersion': version('meridian-admin.json'),
  };
  File('${spec.path}/SOURCE.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(source)}\n');
  print('Pinned engine spec at ${source['engineCommit']} '
      '(${source['publicVersion']}).');
}
