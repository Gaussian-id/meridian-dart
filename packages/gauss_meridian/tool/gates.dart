// ignore_for_file: avoid_print

import 'dart:io';

Future<int> runGate(List<String> arguments) async {
  print('> dart ${arguments.join(' ')}');
  final process = await Process.start(
    Platform.resolvedExecutable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<int> runFlutterGate(List<String> arguments) async {
  print('> flutter ${arguments.join(' ')}');
  try {
    final process = await Process.start(
      'flutter',
      arguments,
      workingDirectory: '../gauss_meridian_flutter',
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    return await process.exitCode;
  } on ProcessException {
    print('Flutter is not on PATH; the Flutter gate cannot pass.');
    return 1;
  }
}

Future<bool> flutterOnPath() async {
  try {
    final result = await Process.run(
      Platform.isWindows ? 'where.exe' : 'which',
      ['flutter'],
    );
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> main() async {
  // [1] Check formatting, analysis and tests in that order.
  final commands = <List<String>>[
    ['format', '--output=none', '--set-exit-if-changed', '.'],
    ['analyze', '--fatal-infos'],
    ['test'],
  ];
  // [2] Add the generated model drift check once Task 2 creates it.
  if (File('tool/generate_admin.dart').existsSync()) {
    commands.add(['run', 'tool/generate_admin.dart', '--check']);
  }
  // [3] Stop at the first red check so no later result masks it.
  for (final command in commands) {
    final exitCode = await runGate(command);
    if (exitCode != 0) {
      exit(exitCode);
    }
  }
  // [4] Flutter analysis and widget tests are required once its package exists.
  if (File('../gauss_meridian_flutter/pubspec.yaml').existsSync()) {
    if (!await flutterOnPath()) {
      print('Flutter is not on PATH; the Flutter gate cannot pass.');
      exit(1);
    }
    for (final command in <List<String>>[
      ['analyze'],
      ['test'],
    ]) {
      final exitCode = await runFlutterGate(command);
      if (exitCode != 0) exit(exitCode);
    }
  }
}
