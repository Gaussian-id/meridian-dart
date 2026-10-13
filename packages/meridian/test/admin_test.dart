import 'dart:convert';
import 'dart:io';

import 'package:meridian/admin.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';
import 'support/seams.dart';

Map<String, Object?> _spec() =>
    jsonDecode(File('../../spec/meridian-admin.json').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;

Object? _fixture(Object? schema, Map<String, Object?> schemas) {
  final definition = _map(schema);
  final reference = definition['\$ref'];
  if (reference is String) {
    return _fixture(schemas[reference.split('/').last], schemas);
  }
  final oneOf = definition['oneOf'];
  if (oneOf is List<Object?>) return _fixture(oneOf.first, schemas);
  final kind = definition['type'];
  if (kind is List<Object?>) {
    return kind.contains('null')
        ? null
        : _fixture({...definition, 'type': kind.first}, schemas);
  }
  switch (kind) {
    case 'object':
      final properties = definition['properties'] == null
          ? <String, Object?>{}
          : _map(definition['properties']);
      final required = (definition['required'] as List<Object?>? ?? const []);
      return <String, Object?>{
        for (final name in required.cast<String>())
          name: _fixture(properties[name], schemas),
      };
    case 'array':
      return <Object?>[];
    case 'integer':
      return 1;
    case 'number':
      return 1.0;
    case 'boolean':
      return true;
    case 'null':
      return null;
    default:
      final enumeration = definition['enum'];
      return enumeration is List<Object?> && enumeration.isNotEmpty
          ? enumeration.first
          : 'value';
  }
}

Map<String, Map<String, Object?>> _integratorOperations() {
  final document = _spec();
  final paths = _map(document['paths']);
  final result = <String, Map<String, Object?>>{};
  for (final path in paths.entries) {
    for (final method in _map(path.value).entries) {
      if (!const {'get', 'post', 'put', 'patch', 'delete'}
          .contains(method.key)) {
        continue;
      }
      final operation = _map(method.value);
      final security = operation['security'] as List<Object?>? ?? const [];
      if (!security.any((entry) => _map(entry).containsKey('IntegratorKey'))) {
        continue;
      }
      result['${method.key.toUpperCase()} ${path.key}'] = operation;
    }
  }
  return result;
}

Scripted _reply(String operationId, {int? status}) {
  final spec = _spec();
  final schemas = _map(_map(spec['components'])['schemas']);
  final operation = _integratorOperations()
      .values
      .singleWhere((item) => item['operationId'] == operationId);
  final responses = _map(operation['responses']);
  final successCode = responses.keys.firstWhere((key) => key.startsWith('2'));
  final response = _map(responses[successCode]);
  final content = response['content'];
  if (content == null) {
    return Scripted(status: status ?? int.parse(successCode));
  }
  final schema = _map(_map(content)['application/json'])['schema'];
  return Scripted(
      status: status ?? int.parse(successCode),
      json: _fixture(schema, schemas));
}

bool _containsPriceKey(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String &&
          RegExp('cost|price', caseSensitive: false)
              .hasMatch(entry.key as String)) {
        return true;
      }
      if (_containsPriceKey(entry.value)) return true;
    }
  } else if (value is List) {
    return value.any(_containsPriceKey);
  }
  return false;
}

void main() {
  late FakeEngine engine;
  late List<Duration> sleeps;

  setUp(() {
    engine = FakeEngine();
    sleeps = recordSleeps();
  });

  MeridianAdmin client({String? key, int? maxRetries}) {
    final instance = MeridianAdmin(
      url: FakeEngine.adminUrl,
      key: key ?? engine.integratorKey,
      httpClient: engine.client,
      maxRetries: maxRetries,
    );
    addTearDown(instance.close);
    return instance;
  }

  test('exactly the 24 pinned IntegratorKey method and path operations',
      () async {
    // [1] Exercise each public operation with its own schema-valid reply.
    final admin = client(maxRetries: 0);
    Future<void> invoke(
        String operationId, Future<Object?> Function() call) async {
      engine.next(_reply(operationId));
      expect(await call(), isA<Ok<Object?>>(), reason: operationId);
    }

    await invoke('usage_usage', () => admin.analytics.usage('p_SENTINEL'));
    await invoke('supplier_catalogue_active', () => admin.catalogue.active());
    await invoke(
        'supplier_catalogue_version', () => admin.catalogue.version(17));
    await invoke('usage_logs', () => admin.logs.list('p_SENTINEL'));
    await invoke('models_catalogue', () => admin.models.list());
    await invoke('models_one', () => admin.models.get('m_SENTINEL'));
    await invoke('orgs_list', () => admin.orgs.list());
    await invoke('orgs_create',
        () => admin.orgs.create(CreateOrganisation(name: 'new org')));
    await invoke(
        'orgs_by_reference', () => admin.orgs.getByReference('r_SENTINEL'));
    await invoke('orgs_get', () => admin.orgs.get('o_SENTINEL'));
    await invoke('projects_list', () => admin.projects.list('o_SENTINEL'));
    await invoke(
        'projects_create',
        () => admin.projects
            .create('o_SENTINEL', CreateProject(name: 'new project')));
    await invoke(
        'projects_get', () => admin.projects.get('o_SENTINEL', 'p_SENTINEL'));
    await invoke('projects_delete',
        () => admin.projects.delete('o_SENTINEL', 'p_SENTINEL'));
    await invoke(
        'projects_rename',
        () => admin.projects
            .update('o_SENTINEL', 'p_SENTINEL', UpdateProject.name('renamed')));
    await invoke(
        'keys_list', () => admin.keys.list('o_SENTINEL', 'p_SENTINEL'));
    await invoke(
        'keys_issue',
        () => admin.keys
            .create('o_SENTINEL', 'p_SENTINEL', IssueKey(name: 'test')));
    await invoke('keys_revoke',
        () => admin.keys.revoke('o_SENTINEL', 'p_SENTINEL', 'k_SENTINEL'));
    await invoke('models_allowlist',
        () => admin.projectModels.get('o_SENTINEL', 'p_SENTINEL'));
    await invoke('models_set_allowlist',
        () => admin.projectModels.put('o_SENTINEL', 'p_SENTINEL', ['m1']));
    await invoke(
        'byok_list', () => admin.providerCredentials.list('o_SENTINEL'));
    await invoke(
        'byok_set',
        () => admin.providerCredentials.put('o_SENTINEL', 'provider_SENTINEL',
            SetCredential(credential: 'test-credential')));
    await invoke(
        'byok_delete',
        () => admin.providerCredentials
            .delete('o_SENTINEL', 'provider_SENTINEL'));
    await invoke(
        'routing_record_get',
        () => admin.routingRecords
            .get('request_SENTINEL', projectId: 'p_SENTINEL'));

    // [2] Normalize only the known sentinel segments and compare to the pin.
    final actual = engine.requests.map((request) {
      final path = request.url.path
          .replaceAll('o_SENTINEL', '{org}')
          .replaceAll('p_SENTINEL', '{project}')
          .replaceAll('m_SENTINEL', '{model}')
          .replaceAll('k_SENTINEL', '{key}')
          .replaceAll('provider_SENTINEL', '{provider}')
          .replaceAll('request_SENTINEL', '{request_id}')
          .replaceAll('r_SENTINEL', '{reference}')
          .replaceAll('/17', '/{version}');
      return '${request.method} $path';
    }).toSet();
    expect(engine.requests, hasLength(24));
    expect(actual, _integratorOperations().keys.toSet());
    expect(admin.orgs, isNotNull);
    expect(() => (admin.orgs as dynamic).update, throwsNoSuchMethodError);
    expect(() => (admin.orgs as dynamic).delete, throwsNoSuchMethodError);
  });

  test('admin bearer is sent to the admin host, with no idempotency key',
      () async {
    engine.next(_reply('orgs_list'));
    expect(await client().orgs.list(), isA<Ok<Object?>>());
    final request = engine.requests.single;
    expect(request.url.origin, Uri.parse(FakeEngine.adminUrl).origin);
    expect(request.headers['authorization'], 'Bearer ${engine.integratorKey}');
    expect(request.headers, isNot(contains('idempotency-key')));
  });

  for (final unsafe in ['', '.', '..', '%2e%2E', '%2E.']) {
    test('unsafe path id $unsafe is refused in every route family', () async {
      final admin = client();
      final calls = <Future<Object?>>[
        admin.keys.revoke('org', 'project', unsafe),
        admin.providerCredentials.delete('org', unsafe),
        admin.projects.get('org', unsafe),
        admin.orgs.getByReference(unsafe),
        admin.routingRecords.get(unsafe, projectId: 'project'),
      ];
      for (final result in await Future.wait(calls)) {
        expect(result, isA<Err<Object?>>());
        expect((result as Err<Object?>).error.code, 'invalid_request');
      }
      expect(engine.requests, isEmpty);
    });
  }

  for (final (value, encoded) in [
    ('kopi-ü-日本-😀', 'kopi-%C3%BC-%E6%97%A5%E6%9C%AC-%F0%9F%98%80'),
    ('a/b', 'a%2Fb'),
    ('%', '%25'),
  ]) {
    test('path id $value is a single encoded segment', () async {
      engine.next(_reply('orgs_get'));
      await client().orgs.get(value);
      expect(
          engine.requests.single.url.toString(), contains('/v1/orgs/$encoded'));
    });
  }

  test('query values are encoded and null optional values omitted', () async {
    engine.next(_reply('usage_logs'));
    await client().logs.list('p 1');
    final uri = engine.requests.single.url;
    expect(uri.queryParameters['project_id'], 'p 1');
    expect(uri.toString(), contains('project_id=p%201'));
    expect(uri.queryParameters, isNot(contains('page_size')));
    expect(uri.queryParameters, isNot(contains('cursor')));
  });

  for (final operation in ['keys_issue', 'projects_create']) {
    test('$operation does not retry a 503', () async {
      engine.next(engineError('service_unavailable'), _reply(operation));
      final admin = client();
      final result = operation == 'keys_issue'
          ? await admin.keys.create('org', 'project', IssueKey())
          : await admin.projects.create('org', CreateProject(name: 'p'));
      expect(result, isA<Err<Object?>>());
      expect(engine.requests, hasLength(1));
      expect(sleeps, isEmpty);
    });
  }

  test('key issue retries rate_limited and returns the API key', () async {
    engine.next(
        engineError('rate_limited'),
        Scripted(status: 201, json: {
          'key_id': 'key-1',
          'api_key': 'issued-secret',
          'key_prefix': 'prefix',
          'message': 'save once',
        }));
    final result = await client().keys.create('org', 'project', IssueKey());
    expect(result, isA<Ok<IssuedKey>>());
    expect((result as Ok<IssuedKey>).data.apiKey, 'issued-secret');
    expect(engine.requests, hasLength(2));
    expect(sleeps, hasLength(1));
  });

  for (final reference in ['ext', null, '']) {
    test('organisation create retry rule for reference $reference', () async {
      engine.next(
          engineError('service_unavailable'),
          engineError('service_unavailable'),
          engineError('service_unavailable'));
      final body =
          CreateOrganisation(name: 'org', externalReference: reference);
      final result = await client().orgs.create(body);
      expect(result, isA<Err<Object?>>());
      expect(engine.requests, hasLength(reference == 'ext' ? 3 : 1));
    });
  }

  test('usage prices and costs are stripped recursively before parsing',
      () async {
    final data = _map(_reply('usage_usage').json);
    final summary = _map(data['summary']);
    summary['total_cost'] = 99;
    summary['cost'] = {'Cost_Charged': 10};
    data['supplier_price'] = 30;
    engine.next(Scripted(json: data));
    final result = await client().analytics.usage('project');
    expect(result, isA<Ok<UsageReport>>());
    expect((result as Ok<UsageReport>).data.summary.totalRequests, 1);
    expect(_containsPriceKey(jsonDecode(jsonEncode(result.data))), isFalse);
  });

  test('catalogue supplier prices are stripped recursively', () async {
    final data = <String, Object?>{
      'version': 1,
      'models': [
        {
          'id': 'm1',
          'provider': 'p',
          'delivery': 'direct',
          'capabilities': {
            'streaming': true,
            'tools': false,
            'vision': false,
            'json_output': false
          },
          'limits': {'context_tokens': 1, 'max_output_tokens': 1},
          'supplier_price': {'input_per_million': 7},
        },
      ],
    };
    engine.next(Scripted(json: data));
    final result = await client().catalogue.active();
    expect(result, isA<Ok<SupplierCatalogueResponse>>());
    expect(
        (result as Ok<SupplierCatalogueResponse>).data.models.single.id, 'm1');
    expect(_containsPriceKey(jsonDecode(jsonEncode(result.data))), isFalse);
  });

  test('routing-record price keys are stripped inside opaque record', () async {
    engine.next(Scripted(json: {
      'org_id': 'org',
      'project_id': 'project',
      'request_id': 'request',
      'recorded_at_ms': 1,
      'record': {
        'details': [
          {'supplier_price': 5, 'Cost_Charged': 3, 'safe': 'kept'}
        ]
      },
    }));
    final result =
        await client().routingRecords.get('request', projectId: 'project');
    expect(result, isA<Ok<RoutingRecordBody>>());
    final record = (result as Ok<RoutingRecordBody>).data.record;
    expect(record, {
      'details': [
        {'safe': 'kept'}
      ]
    });
  });

  test('delete returns Ok<void>', () async {
    engine.next(const Scripted(status: 204));
    expect(await client().projects.delete('org', 'project'), isA<Ok<void>>());
  });

  test('missing key is a configuration error without a request', () async {
    final result = await client(key: '').orgs.list();
    expect(result, isA<Err<Object?>>());
    expect((result as Err<Object?>).error.type, 'client_error');
    expect(engine.requests, isEmpty);
  });

  test('malformed admin reply has typed network_error', () async {
    engine.next(const Scripted(json: {'unexpected': true}));
    final result = await client().orgs.get('org');
    expect(result, isA<Err<Object?>>());
    expect((result as Err<Object?>).error.code, 'network_error');
    expect((result as Err<Object?>).error.message,
        'The admin response did not have the expected shape.');
  });

  test('project update bodies have exactly one selected field', () async {
    final admin = client();
    engine.next(_reply('projects_rename'), _reply('projects_rename'));
    expect(
        await admin.projects
            .update('org', 'project', UpdateProject.defaultModel(null)),
        isA<Ok<Object?>>());
    expect(
        await admin.projects
            .update('org', 'project', UpdateProject.defaultEffort('high')),
        isA<Ok<Object?>>());
    expect(engine.bodies(), [
      {'default_model': null},
      {'default_effort': 'high'},
    ]);
  });

  test('handwritten wireFields equal pinned request schema properties', () {
    final schemas = _map(_map(_spec()['components'])['schemas']);
    for (final (name, fields) in [
      ('CreateOrganisation', CreateOrganisation.wireFields),
      ('CreateProject', CreateProject.wireFields),
      ('UpdateProject', UpdateProject.wireFields),
      ('IssueKey', IssueKey.wireFields),
      ('SetCredential', SetCredential.wireFields),
    ]) {
      expect(
          fields.toSet(), _map(_map(schemas[name])['properties']).keys.toSet(),
          reason: name);
    }
  });
}
