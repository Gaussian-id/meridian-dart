import 'package:http/http.dart' as http;

import 'admin_bodies.dart';
import 'admin_routes.dart';
import 'config.dart';
import 'env.dart';
import 'errors.dart';
import 'generated/admin_models.dart';
import 'prices.dart';
import 'result.dart';
import 'runtime.dart';
import 'transport.dart';
import 'version.dart';

/// Integrator-key client for the Meridian admin API.
final class MeridianAdmin {
  MeridianAdmin._(this._transport)
      : orgs = AdminOrgs(_transport),
        projects = AdminProjects(_transport),
        keys = AdminKeys(_transport),
        providerCredentials = AdminProviderCredentials(_transport),
        projectModels = AdminProjectModels(_transport),
        catalogue = AdminCatalogue(_transport),
        models = AdminModels(_transport),
        analytics = AdminAnalytics(_transport),
        logs = AdminLogs(_transport),
        routingRecords = AdminRoutingRecords(_transport);

  /// Creates an admin client from explicit options or environment values.
  factory MeridianAdmin({
    String? url,
    String? key,
    Duration? timeout,
    int? maxRetries,
    http.Client? httpClient,
  }) {
    // [1] Refuse browser and Flutter runtimes before reading configuration.
    if (adminRuntimeRefusal != null) {
      return MeridianAdmin._(
          Transport.refused(configError(adminRuntimeRefusal!)));
    }
    final endpoint = url ?? envReader('MERIDIAN_ADMIN_URL');
    final credential = key ?? envReader('MERIDIAN_INTEGRATOR_KEY');
    // [2] Reject missing or unsafe values without sending a request.
    final urlError = urlRefusal(endpoint, 'admin URL');
    if (urlError != null) {
      return MeridianAdmin._(Transport.refused(configError(urlError)));
    }
    final keyError = keyRefusal(credential, 'integrator key');
    if (keyError != null) {
      return MeridianAdmin._(Transport.refused(configError(keyError)));
    }
    // [3] Share the admin transport across the ten operation groups.
    return MeridianAdmin._(Transport(
      baseUrl: endpoint!,
      key: credential,
      timeout: timeout,
      maxRetries: maxRetries,
      httpClient: httpClient,
      userAgent: 'meridian-dart/$meridianVersion',
    ));
  }

  final Transport _transport;

  /// Organisation operations.
  final AdminOrgs orgs;

  /// Project operations.
  final AdminProjects projects;

  /// Project-key operations.
  final AdminKeys keys;

  /// Provider credential operations.
  final AdminProviderCredentials providerCredentials;

  /// Project model allowlist operations.
  final AdminProjectModels projectModels;

  /// Supplier catalogue operations.
  final AdminCatalogue catalogue;

  /// Admin model operations.
  final AdminModels models;

  /// Usage analytics operations.
  final AdminAnalytics analytics;

  /// Usage log operations.
  final AdminLogs logs;

  /// Routing-record operations.
  final AdminRoutingRecords routingRecords;

  /// Closes the underlying HTTP client.
  void close() => _transport.close();
}

Future<MeridianResult<T>> _request<T>(
  Transport transport,
  String method,
  String template,
  List<String> ids,
  T? Function(Object?) parse, {
  Map<String, String?> query = const {},
  Object? body,
  bool hasBody = false,
  bool retry = true,
}) async {
  // [1] Encode route segments before constructing the HTTP call.
  final resolved = route(template, ids);
  if (resolved is Err<String>) return Err(resolved.error);
  final path = _withQuery((resolved as Ok<String>).data, query);
  final call = hasBody
      ? Call.json(method: method, path: path, body: body, retry: retry)
      : Call(method: method, path: path, retry: retry);
  // [2] Strip all price and cost fields before validating the typed result.
  final reply = await transport.json(call);
  if (reply is Err<JsonReply>) return Err(reply.error);
  final value = (reply as Ok<JsonReply>).data;
  final parsed = parse(withoutPrices(value.value));
  if (parsed == null) {
    return Err(clientError(
        'network_error', 'The admin response did not have the expected shape.',
        requestId: value.requestId));
  }
  return Ok(parsed);
}

Future<MeridianResult<void>> _delete(
    Transport transport, String template, List<String> ids) async {
  final resolved = route(template, ids);
  if (resolved is Err<String>) return Err(resolved.error);
  final reply = await transport
      .json(Call(method: 'DELETE', path: (resolved as Ok<String>).data));
  if (reply is Err<JsonReply>) return Err(reply.error);
  return const Ok<void>(null);
}

String _withQuery(String path, Map<String, String?> values) {
  final entries = values.entries
      .where((entry) => entry.value != null)
      .map((entry) => '${Uri.encodeComponent(entry.key)}='
          '${Uri.encodeComponent(entry.value!)}');
  final encoded = entries.join('&');
  return encoded.isEmpty ? path : '$path?$encoded';
}

List<T>? _parseList<T>(Object? value, T? Function(Object?) parse) {
  if (value is! List) return null;
  final items = <T>[];
  for (final entry in value) {
    final item = parse(entry);
    if (item == null) return null;
    items.add(item);
  }
  return List<T>.unmodifiable(items);
}

/// Organisation operations available to an integrator key.
final class AdminOrgs {
  /// Creates the organisation operation group.
  const AdminOrgs(this._transport);
  final Transport _transport;

  /// Lists organisations.
  Future<MeridianResult<List<OrganisationBody>>> list() => _request(
      _transport,
      'GET',
      '/v1/orgs',
      const [],
      (value) => _parseList(value, OrganisationBody.tryParse));

  /// Creates an organisation, retrying only with a stable external reference.
  Future<MeridianResult<OrganisationBody>> create(CreateOrganisation body) =>
      _request(
          _transport, 'POST', '/v1/orgs', const [], OrganisationBody.tryParse,
          body: body.toJson(),
          hasBody: true,
          retry: body.externalReference?.isNotEmpty ?? false);

  /// Fetches an organisation by its external reference.
  Future<MeridianResult<OrganisationBody>> getByReference(String reference) =>
      _request(_transport, 'GET', '/v1/orgs/by-reference/{}', [reference],
          OrganisationBody.tryParse);

  /// Fetches an organisation by id.
  Future<MeridianResult<OrganisationBody>> get(String org) => _request(
      _transport, 'GET', '/v1/orgs/{}', [org], OrganisationBody.tryParse);
}

/// Project operations available to an integrator key.
final class AdminProjects {
  /// Creates the project operation group.
  const AdminProjects(this._transport);
  final Transport _transport;

  /// Lists projects in one organisation.
  Future<MeridianResult<List<ProjectBody>>> list(String org) => _request(
      _transport,
      'GET',
      '/v1/orgs/{}/projects',
      [org],
      (value) => _parseList(value, ProjectBody.tryParse));

  /// Creates a project without retrying transient server failures.
  Future<MeridianResult<ProjectBody>> create(String org, CreateProject body) =>
      _request(_transport, 'POST', '/v1/orgs/{}/projects', [org],
          ProjectBody.tryParse,
          body: body.toJson(), hasBody: true, retry: false);

  /// Fetches one project.
  Future<MeridianResult<ProjectBody>> get(String org, String project) =>
      _request(_transport, 'GET', '/v1/orgs/{}/projects/{}', [org, project],
          ProjectBody.tryParse);

  /// Updates exactly one project field.
  Future<MeridianResult<ProjectBody>> update(
          String org, String project, UpdateProject body) =>
      _request(_transport, 'PATCH', '/v1/orgs/{}/projects/{}', [org, project],
          ProjectBody.tryParse,
          body: body.toJson(), hasBody: true);

  /// Deletes one project.
  Future<MeridianResult<void>> delete(String org, String project) =>
      _delete(_transport, '/v1/orgs/{}/projects/{}', [org, project]);
}

/// Project-key operations available to an integrator key.
final class AdminKeys {
  /// Creates the project-key operation group.
  const AdminKeys(this._transport);
  final Transport _transport;

  /// Lists keys without their secrets.
  Future<MeridianResult<List<KeyBody>>> list(String org, String project) =>
      _request(_transport, 'GET', '/v1/orgs/{}/projects/{}/keys',
          [org, project], (value) => _parseList(value, KeyBody.tryParse));

  /// Issues a key; rate limiting is the only retried failure.
  Future<MeridianResult<IssuedKey>> create(
          String org, String project, IssueKey body) =>
      _request(_transport, 'POST', '/v1/orgs/{}/projects/{}/keys',
          [org, project], IssuedKey.tryParse,
          body: body.toJson(), hasBody: true, retry: false);

  /// Revokes a key.
  Future<MeridianResult<void>> revoke(String org, String project, String key) =>
      _delete(
          _transport, '/v1/orgs/{}/projects/{}/keys/{}', [org, project, key]);
}

/// Provider credential operations available to an integrator key.
final class AdminProviderCredentials {
  /// Creates the provider-credential operation group.
  const AdminProviderCredentials(this._transport);
  final Transport _transport;

  /// Lists credential metadata for an organisation.
  Future<MeridianResult<List<CredentialMetadata>>> list(String org) => _request(
      _transport,
      'GET',
      '/v1/orgs/{}/provider-credentials',
      [org],
      (value) => _parseList(value, CredentialMetadata.tryParse));

  /// Sets one provider credential.
  Future<MeridianResult<CredentialMetadata>> put(
          String org, String provider, SetCredential body) =>
      _request(_transport, 'PUT', '/v1/orgs/{}/provider-credentials/{}',
          [org, provider], CredentialMetadata.tryParse,
          body: body.toJson(), hasBody: true);

  /// Deletes one provider credential.
  Future<MeridianResult<void>> delete(String org, String provider) => _delete(
      _transport, '/v1/orgs/{}/provider-credentials/{}', [org, provider]);
}

/// Project model allowlist operations.
final class AdminProjectModels {
  /// Creates the project allowlist operation group.
  const AdminProjectModels(this._transport);
  final Transport _transport;

  /// Fetches the current allowlist.
  Future<MeridianResult<ModelAllowlist>> get(String org, String project) =>
      _request(_transport, 'GET', '/v1/orgs/{}/projects/{}/models',
          [org, project], ModelAllowlist.tryParse);

  /// Replaces the current allowlist.
  Future<MeridianResult<ModelAllowlist>> put(
          String org, String project, List<String> models) =>
      _request(_transport, 'PUT', '/v1/orgs/{}/projects/{}/models',
          [org, project], ModelAllowlist.tryParse,
          body: {'models': models}, hasBody: true);
}

/// Supplier catalogue operations.
final class AdminCatalogue {
  /// Creates the supplier catalogue operation group.
  const AdminCatalogue(this._transport);
  final Transport _transport;

  /// Fetches the active catalogue.
  Future<MeridianResult<SupplierCatalogueResponse>> active() => _request(
      _transport,
      'GET',
      '/v1/catalogue',
      const [],
      SupplierCatalogueResponse.tryParse);

  /// Fetches one catalogue version.
  Future<MeridianResult<SupplierCatalogueResponse>> version(int version) =>
      _request(_transport, 'GET', '/v1/catalogue/{}', ['$version'],
          SupplierCatalogueResponse.tryParse);
}

/// Admin model catalogue operations.
final class AdminModels {
  /// Creates the admin model operation group.
  const AdminModels(this._transport);
  final Transport _transport;

  /// Lists all admin catalogue models.
  Future<MeridianResult<List<CatalogueModelBody>>> list() => _request(
      _transport,
      'GET',
      '/v1/models',
      const [],
      (value) => _parseList(value, CatalogueModelBody.tryParse));

  /// Fetches one model.
  Future<MeridianResult<CatalogueModelBody>> get(String model) => _request(
      _transport, 'GET', '/v1/models/{}', [model], CatalogueModelBody.tryParse);
}

/// Usage analytics operations.
final class AdminAnalytics {
  /// Creates the usage analytics operation group.
  const AdminAnalytics(this._transport);
  final Transport _transport;

  /// Fetches usage for a project and optional time range.
  Future<MeridianResult<UsageReport>> usage(String projectId,
          {String? from, String? to}) =>
      _request(_transport, 'GET', '/v1/analytics/usage', const [],
          UsageReport.tryParse,
          query: {'project_id': projectId, 'from': from, 'to': to});
}

/// Usage log operations.
final class AdminLogs {
  /// Creates the usage log operation group.
  const AdminLogs(this._transport);
  final Transport _transport;

  /// Fetches one page of logs for a project.
  Future<MeridianResult<LogPage>> list(String projectId,
          {int? pageSize, String? cursor}) =>
      _request(_transport, 'GET', '/v1/logs', const [], LogPage.tryParse,
          query: {
            'project_id': projectId,
            'page_size': pageSize?.toString(),
            'cursor': cursor,
          });
}

/// Routing-record operations.
final class AdminRoutingRecords {
  /// Creates the routing-record operation group.
  const AdminRoutingRecords(this._transport);
  final Transport _transport;

  /// Fetches a routing record in a project.
  Future<MeridianResult<RoutingRecordBody>> get(String requestId,
          {required String projectId}) =>
      _request(_transport, 'GET', '/v1/routing-records/{}', [requestId],
          RoutingRecordBody.tryParse,
          query: {'project_id': projectId});
}
