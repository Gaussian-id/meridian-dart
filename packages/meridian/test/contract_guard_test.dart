import 'dart:io';

import 'package:test/test.dart';

import '../tool/contract.dart' as guard;

void main() {
  test('paid keys are reported by name only', () {
    const cases = <(String, List<String>)>[
      ('GAUSSMERIDIAN_GEMINI_API_KEY=abc', ['GAUSSMERIDIAN_GEMINI_API_KEY']),
      (
        'export GAUSSMERIDIAN_OPENROUTER_API_KEY="x"\r\n',
        ['GAUSSMERIDIAN_OPENROUTER_API_KEY']
      ),
      ('gaussmeridian_gemini_api_key = y', ['GAUSSMERIDIAN_GEMINI_API_KEY']),
      ('# GAUSSMERIDIAN_GEMINI_API_KEY=abc', []),
      ('GAUSSMERIDIAN_GEMINI_API_KEY=', []),
      ('GAUSSMERIDIAN_GEMINI_API_KEY=""', []),
      ("GAUSSMERIDIAN_GEMINI_API_KEY=''  # empty", []),
    ];
    for (final (text, expected) in cases) {
      expect(guard.paidKeysIn(text), expected);
    }
  });

  test('all eight provider names are recognized once', () {
    const providers = [
      'GEMINI',
      'OPENROUTER',
      'OPENAI',
      'ANTHROPIC',
      'XAI',
      'DEEPSEEK',
      'MISTRAL',
      'QWEN',
    ];
    final names = providers
        .map((provider) => 'GAUSSMERIDIAN_${provider}_API_KEY')
        .toList();
    final text = [
      for (final name in names) '$name=fixture',
      '${names.first}=fixture-again',
      'OTHER_PROVIDER_API_KEY=fixture',
    ].join('\n');
    expect(guard.paidKeysIn(text), names);
  });

  test('loopback is judged by the parsed hostname', () {
    const cases = <(String, bool)>[
      ('http://127.0.0.1:8180', true),
      ('http://localhost:8181', true),
      ('http://[::1]:8180', true),
      ('http://127.0.0.1.evil.com', false),
      ('http://localhost@evil.com', false),
      ('https://api.example.com', false),
      ('not a url', false),
    ];
    for (final (url, expected) in cases) {
      expect(guard.isLoopbackUrl(url), expected, reason: url);
    }
  });

  test('containment resolves paths and excludes the parent itself', () {
    final root = Directory.systemTemp.createTempSync('meridian-contract-');
    addTearDown(() => root.deleteSync(recursive: true));
    final runtime =
        Directory('${root.path}${Platform.pathSeparator}MeridianEngine')
          ..createSync();
    final inside =
        File('${runtime.path}${Platform.pathSeparator}meridian-engine.env');
    final outside = File('${runtime.path}${Platform.pathSeparator}..'
        '${Platform.pathSeparator}elsewhere.env');
    expect(guard.isInside(runtime.path, inside.path), isTrue);
    expect(guard.isInside(runtime.path, outside.path), isFalse);
    expect(guard.isInside(runtime.path, runtime.path), isFalse);
  });
}
