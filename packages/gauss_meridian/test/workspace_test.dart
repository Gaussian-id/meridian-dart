import 'dart:io';

import 'package:gauss_meridian/gauss_meridian.dart';
import 'package:test/test.dart';

void main() {
  test('the package version is semantic', () {
    expect(
      meridianVersion,
      matches(RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')),
    );
  });

  test('meridianVersion matches the pubspec version', () {
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().singleWhere((line) => line.startsWith('version:'));
    expect(meridianVersion, line.substring('version:'.length).trim());
  });

  test('the package declares only the approved dependencies', () {
    // [1] Read the two dependency sections without adding a YAML parser.
    final lines = File('pubspec.yaml').readAsLinesSync();
    final sections = <String, Set<String>>{};
    String? current;
    for (final line in lines) {
      if (line == 'dependencies:' || line == 'dev_dependencies:') {
        current = line.substring(0, line.length - 1);
        sections[current] = <String>{};
      } else if (line.isNotEmpty && !line.startsWith(' ')) {
        current = null;
      } else if (current != null &&
          line.startsWith('  ') &&
          !line.startsWith('    ')) {
        final name = line.trim().split(':').first;
        sections[current]!.add(name);
      }
    }
    // [2] Reject both missing and unapproved direct dependencies.
    expect(sections['dependencies'], {'http', 'shelf'});
    expect(sections['dev_dependencies'], {'lints', 'test'});
  });
}
