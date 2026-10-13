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
}
