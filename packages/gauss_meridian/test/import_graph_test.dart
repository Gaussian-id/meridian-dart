import 'package:test/test.dart';

import 'support/import_graph.dart';

void main() {
  test('browser entry excludes server, admin, forward, env and Shelf', () {
    final paths = reachableLibraries('lib/browser.dart');
    expect(
        paths,
        containsAll([
          'lib/src/browser_client.dart',
          'lib/src/chat.dart',
          'lib/src/transport.dart',
          'package:http'
        ]));
    expect(paths, isNot(contains('package:shelf')));
    for (final path in paths) {
      expect(
          path,
          isNot(matches(RegExp(
              r'(^|/)server_client\.dart$|(^|/)admin_[^/]*\.dart$|'
              r'(^|/)forward\.dart$|(^|/)env[^/]*\.dart$|(^|/)generated/'))));
    }
  });

  test('server entry does not reach admin or forwarding implementation', () {
    final paths = reachableLibraries('lib/gauss_meridian.dart');
    expect(
        paths,
        containsAll([
          'lib/src/runtime_vm.dart',
          'lib/src/runtime_flutter.dart',
          'lib/src/runtime_web.dart'
        ]));
    for (final path in paths) {
      expect(
          path,
          isNot(
              matches(RegExp(r'(^|/)admin_[^/]*\.dart$|(^|/)forward\.dart$'))));
    }
  });
}
