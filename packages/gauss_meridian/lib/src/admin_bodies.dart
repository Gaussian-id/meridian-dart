/// The request body for creating an organisation.
final class CreateOrganisation {
  /// Creates an organisation request.
  const CreateOrganisation({
    required this.name,
    this.slug,
    this.externalReference,
  });

  /// The organisation name.
  final String name;

  /// An optional URL-friendly slug.
  final String? slug;

  /// An optional caller-owned reference for repeatable creation.
  final String? externalReference;

  /// The fields in the pinned request schema.
  static const wireFields = <String>{'external_reference', 'name', 'slug'};

  /// Encodes only the supplied optional fields.
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (slug != null) 'slug': slug,
    if (externalReference != null) 'external_reference': externalReference,
  };
}

/// The request body for creating a project.
final class CreateProject {
  /// Creates a project request.
  const CreateProject({required this.name});

  /// The project name.
  final String name;

  /// The fields in the pinned request schema.
  static const wireFields = <String>{'name'};

  /// Encodes the request body.
  Map<String, Object?> toJson() => <String, Object?>{'name': name};
}

/// A project update that sends exactly one field.
final class UpdateProject {
  const UpdateProject._(this._field, this._value);

  /// Updates the project name.
  const UpdateProject.name(String value) : this._('name', value);

  /// Updates the project status.
  const UpdateProject.status(String value) : this._('status', value);

  /// Sets or clears the default model; null explicitly clears it.
  const UpdateProject.defaultModel(String? value)
    : this._('default_model', value);

  /// Updates the default effort.
  const UpdateProject.defaultEffort(String value)
    : this._('default_effort', value);

  final String _field;
  final Object? _value;

  /// The fields in the pinned request schema.
  static const wireFields = <String>{
    'default_effort',
    'default_model',
    'name',
    'status',
  };

  /// Encodes just the selected field, including an explicit null.
  Map<String, Object?> toJson() => <String, Object?>{_field: _value};
}

/// The request body for issuing an API key.
final class IssueKey {
  /// Creates a key issue request.
  const IssueKey({
    this.name,
    this.expiresInDays,
    this.rateLimitPerMinute,
    this.rateLimitPerDay,
  });

  /// An optional display name.
  final String? name;

  /// An optional validity period in days.
  final int? expiresInDays;

  /// An optional request limit per minute.
  final int? rateLimitPerMinute;

  /// An optional request limit per day.
  final int? rateLimitPerDay;

  /// The fields in the pinned request schema.
  static const wireFields = <String>{
    'expires_in_days',
    'name',
    'rate_limit_per_day',
    'rate_limit_per_minute',
  };

  /// Encodes only the supplied fields.
  Map<String, Object?> toJson() => <String, Object?>{
    if (name != null) 'name': name,
    if (expiresInDays != null) 'expires_in_days': expiresInDays,
    if (rateLimitPerMinute != null) 'rate_limit_per_minute': rateLimitPerMinute,
    if (rateLimitPerDay != null) 'rate_limit_per_day': rateLimitPerDay,
  };
}

/// The request body for setting a provider credential.
final class SetCredential {
  /// Creates a credential request.
  const SetCredential({required this.credential, this.policy});

  /// The secret sent to the admin API.
  final String credential;

  /// An optional credential policy.
  final Map<String, Object?>? policy;

  /// The fields in the pinned request schema.
  static const wireFields = <String>{'credential', 'policy'};

  /// Encodes the credential and any supplied policy.
  Map<String, Object?> toJson() => <String, Object?>{
    'credential': credential,
    if (policy != null) 'policy': policy,
  };
}
