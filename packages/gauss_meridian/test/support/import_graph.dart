import 'dart:io';

/// Find local libraries and package names reachable from an entry library.
Set<String> reachableLibraries(String entryFile) {
  // [1] Keep paths relative to the package root for stable test output.
  final root = Directory.current.absolute;
  final pending = <File>[File(entryFile).absolute];
  final reachable = <String>{};
  final directive =
      RegExp(r'''\b(?:import|export)\s+['"][^'"]+['"][^;]*;''', dotAll: true);
  final quoted = RegExp(r'''['"]([^'"]+)['"]''');

  // [2] Walk imports and exports, including every conditional URI branch.
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    final normalized = file.absolute.path.replaceAll('\\', '/');
    final rootPath = root.path.replaceAll('\\', '/');
    final relative = normalized.startsWith('$rootPath/')
        ? normalized.substring(rootPath.length + 1)
        : normalized;
    if (!reachable.add(relative)) continue;
    if (!file.existsSync()) continue;
    final source = file.readAsStringSync();
    for (final match in directive.allMatches(source)) {
      for (final uriMatch in quoted.allMatches(match.group(0)!)) {
        final uri = uriMatch[1]!;
        if (uri.startsWith('dart:')) continue;
        if (uri.startsWith('package:')) {
          final packageUri = Uri.parse(uri);
          final parts = packageUri.pathSegments;
          if (parts.first == 'gauss_meridian') {
            pending.add(File.fromUri(
                root.uri.resolve('lib/${parts.skip(1).join('/')}')));
          } else {
            reachable.add('package:${parts.first}');
          }
        } else {
          pending.add(File.fromUri(file.parent.uri.resolve(uri)));
        }
      }
    }
  }
  return reachable;
}
