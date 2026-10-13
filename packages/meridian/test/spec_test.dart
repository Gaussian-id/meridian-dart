import 'dart:convert';
import 'dart:io';

import 'package:meridian/meridian.dart';
import 'package:meridian/src/generated/admin_models.dart';
import 'package:test/test.dart';

void main() {
  test('the pinned source records the engine revision and API version', () {
    final source = jsonDecode(File('../../spec/SOURCE.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(source['engineCommit'], matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(engineSpecCommit, source['engineCommit']);
    expect(engineApiVersion, source['publicVersion']);
  });

  test('generated admin models have no price or cost identifiers', () {
    final text = File('lib/src/generated/admin_models.dart').readAsStringSync();
    final identifiers = RegExp(r'\b[A-Za-z_][A-Za-z_0-9]*\b')
        .allMatches(text)
        .map((match) => match.group(0)!);
    expect(
        identifiers.where((name) =>
            RegExp('cost|price', caseSensitive: false).hasMatch(name)),
        isEmpty);
  });

  test('generated admin models cover each integrator response shape', () {
    expect(OrganisationBody.isValid, isA<Function>());
    expect(ProjectBody.isValid, isA<Function>());
    expect(IssuedKey.isValid, isA<Function>());
    expect(KeyBody.isValid, isA<Function>());
    expect(ModelAllowlist.isValid, isA<Function>());
    expect(CredentialMetadata.isValid, isA<Function>());
    expect(CatalogueModelBody.isValid, isA<Function>());
    expect(SupplierCatalogueResponse.isValid, isA<Function>());
    expect(LogPage.isValid, isA<Function>());
    expect(UsageReport.isValid, isA<Function>());
    expect(RoutingRecordBody.isValid, isA<Function>());
  });

  test('a project requires a string name and includes default effort', () {
    final sample = <String, Object?>{
      'id': 'p',
      'ref': 'p',
      'name': 'Project',
      'org_id': 'o',
      'status': 'active',
      'default_model': null,
      'default_effort': 'high',
      'created_at': '2026-10-14T00:00:00Z',
    };
    expect(ProjectBody.tryParse(sample)?.defaultEffort, 'high');
    expect(ProjectBody.tryParse({...sample}..remove('name')), isNull);
    expect(ProjectBody.tryParse({...sample, 'name': 3}), isNull);
  });

  test('a nullable getter ignores a wrong-typed value', () {
    final sample = <String, Object?>{
      'id': 'm',
      'provider': 'p',
      'delivery': 'direct',
      'capabilities': <String, Object?>{
        'streaming': true,
        'tools': true,
        'vision': false,
        'json_output': true,
      },
      'limits': <String, Object?>{
        'context_tokens': 100,
        'max_output_tokens': 10,
      },
      'routing_class': 3,
    };
    expect(() => SupplierModelResponse.tryParse(sample)?.routingClass,
        returnsNormally);
    expect(SupplierModelResponse.tryParse(sample)?.routingClass, isNull);
  });

  test('required nested objects and array elements are validated', () {
    expect(
        ModelAllowlist.tryParse({
          'models': ['m1', 3]
        }),
        isNull);
    expect(
      CatalogueModelBody.tryParse({
        'id': 'm',
        'provider': 'p',
        'capabilities': {'streaming': true},
        'context_tokens': 100,
        'max_output_tokens': 10,
      }),
      isNull,
    );
  });
}
