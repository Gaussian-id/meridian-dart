/// Public request and response models for the Meridian chat API.
library;

import 'prices.dart';

/// A chat message, with provider-specific fields kept in [extra].
final class ChatMessage {
  /// Creates a message with an advisory role and arbitrary content.
  ChatMessage(
      {required this.role, this.content, Map<String, Object?> extra = const {}})
      : extra = Map.unmodifiable(extra);

  /// Creates a system message.
  ChatMessage.system(String content) : this(role: 'system', content: content);

  /// Creates a user message.
  ChatMessage.user(String content) : this(role: 'user', content: content);

  /// Creates an assistant message.
  ChatMessage.assistant(String content)
      : this(role: 'assistant', content: content);

  /// The OpenAPI fields represented by this model.
  static const wireFields = {'role', 'content'};

  /// The message role.
  final String role;

  /// Text, content parts, or null for a tool call.
  final Object? content;

  /// Additional fields forwarded to the engine.
  final Map<String, Object?> extra;

  /// Reads a message from a JSON object.
  static ChatMessage? fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['role'] is! String) {
      return null;
    }
    final fields = Map<String, Object?>.from(value);
    fields.remove('role');
    fields.remove('content');
    return ChatMessage(
      role: value['role'] as String,
      content: value['content'],
      extra: fields,
    );
  }

  /// Writes this message, with typed fields taking precedence.
  Map<String, Object?> toJson() {
    final fields = Map<String, Object?>.from(extra)
      ..remove('role')
      ..remove('content');
    return {...fields, 'role': role, 'content': content};
  }
}

/// Parameters for a buffered or streamed chat call.
final class ChatParams {
  /// Creates a chat request without selecting a default model.
  ChatParams({
    required List<ChatMessage> messages,
    this.model,
    this.temperature,
    this.maxTokens,
    Map<String, Object?> extra = const {},
  })  : messages = List.unmodifiable(messages),
        extra = Map.unmodifiable(extra);

  /// The OpenAPI fields represented by typed members.
  static const wireFields = {'messages', 'model', 'temperature', 'max_tokens'};

  /// Messages in conversation order.
  final List<ChatMessage> messages;

  /// Optional engine model id; null leaves routing to the engine.
  final String? model;

  /// Optional sampling temperature.
  final num? temperature;

  /// Optional maximum output tokens.
  final int? maxTokens;

  /// Additional request fields forwarded to the engine.
  final Map<String, Object?> extra;

  /// Writes this request, with typed fields taking precedence.
  Map<String, Object?> toJson() {
    // [1] Remove extras that collide with typed fields.
    final fields = Map<String, Object?>.from(extra)
      ..remove('messages')
      ..remove('model')
      ..remove('temperature')
      ..remove('max_tokens');
    // [2] Add only the optional typed values the caller supplied.
    return {
      ...fields,
      'messages': messages.map((message) => message.toJson()).toList(),
      if (model != null) 'model': model,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
    };
  }
}

/// The three token counts Meridian exposes.
final class TokenUsage {
  /// Creates a usage record; absent counts remain absent.
  const TokenUsage(
      {this.promptTokens, this.completionTokens, this.totalTokens});

  /// The allowed usage fields from the pinned schema.
  static const wireFields = {
    'prompt_tokens',
    'completion_tokens',
    'total_tokens',
  };

  /// Prompt tokens, if reported.
  final int? promptTokens;

  /// Completion tokens, if reported.
  final int? completionTokens;

  /// Total tokens, if reported.
  final int? totalTokens;

  /// Reads only integer token counts, ignoring details and other fields.
  static TokenUsage? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    return TokenUsage(
      promptTokens:
          value['prompt_tokens'] is int ? value['prompt_tokens'] as int : null,
      completionTokens: value['completion_tokens'] is int
          ? value['completion_tokens'] as int
          : null,
      totalTokens:
          value['total_tokens'] is int ? value['total_tokens'] as int : null,
    );
  }

  /// Writes only present integer token counts.
  Map<String, Object?> toJson() => {
        if (promptTokens != null) 'prompt_tokens': promptTokens,
        if (completionTokens != null) 'completion_tokens': completionTokens,
        if (totalTokens != null) 'total_tokens': totalTokens,
      };
}

/// A chat reply message from the assistant.
final class AssistantMessage {
  /// Creates an assistant reply message.
  AssistantMessage({
    required this.role,
    required this.content,
    this.reasoning,
    this.refusal,
    List<Object?>? toolCalls,
  }) : toolCalls = toolCalls == null ? null : List.unmodifiable(toolCalls);

  /// The exact fields of the pinned assistant-message schema.
  static const wireFields = {
    'role',
    'content',
    'reasoning',
    'reasoning_content',
    'refusal',
    'tool_calls',
  };

  /// The reply role.
  final String role;

  /// Reply text, which can be null for a tool call.
  final String? content;

  /// Reasoning text, when supplied.
  final String? reasoning;

  /// Refusal text, when supplied.
  final String? refusal;

  /// Tool calls, when supplied.
  final List<Object?>? toolCalls;

  /// Reads an assistant message, rejecting missing or mistyped required fields.
  static AssistantMessage? fromJson(Object? value) {
    // [1] Validate the required reply fields and optional scalar fields.
    if (value is! Map<String, dynamic> ||
        value['role'] != 'assistant' ||
        !value.containsKey('content') ||
        (value['content'] != null && value['content'] is! String) ||
        (value['reasoning'] != null && value['reasoning'] is! String) ||
        (value['reasoning_content'] != null &&
            value['reasoning_content'] is! String) ||
        (value['refusal'] != null && value['refusal'] is! String)) {
      return null;
    }
    // [2] Preserve supported tool calls and normalize the reasoning alias.
    final calls = value['tool_calls'];
    if (calls != null &&
        (calls is! List ||
            calls.any((call) => call is! Map<String, dynamic>))) {
      return null;
    }
    return AssistantMessage(
      role: 'assistant',
      content: value['content'] as String?,
      reasoning: (value['reasoning'] ?? value['reasoning_content']) as String?,
      refusal: value['refusal'] as String?,
      toolCalls: calls == null ? null : List<Object?>.from(calls as List),
    );
  }

  /// Writes the normalized assistant message.
  Map<String, Object?> toJson() => {
        'role': role,
        'content': content,
        if (reasoning != null) 'reasoning': reasoning,
        if (refusal != null) 'refusal': refusal,
        if (toolCalls != null) 'tool_calls': toolCalls,
      };
}

/// One choice in a chat completion.
final class ChatChoice {
  /// Creates a choice.
  const ChatChoice(
      {required this.index, required this.message, required this.finishReason});

  /// The exact fields of the pinned choice schema.
  static const wireFields = {'index', 'message', 'finish_reason'};

  /// Choice index.
  final int index;

  /// Assistant reply.
  final AssistantMessage message;

  /// Why generation stopped.
  final String finishReason;

  /// Reads a choice, rejecting missing or mistyped required fields.
  static ChatChoice? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['index'] is! int ||
        (value['index'] as int) < 0 ||
        !const {'stop', 'length', 'tool_calls', 'content_filter'}
            .contains(value['finish_reason'])) {
      return null;
    }
    final message = AssistantMessage.fromJson(value['message']);
    if (message == null) return null;
    return ChatChoice(
        index: value['index'] as int,
        message: message,
        finishReason: value['finish_reason'] as String);
  }

  /// Writes this choice.
  Map<String, Object?> toJson() => {
        'index': index,
        'message': message.toJson(),
        'finish_reason': finishReason,
      };
}

/// A buffered chat completion.
final class ChatCompletion {
  /// Creates a parsed completion.
  ChatCompletion({
    required this.id,
    required this.model,
    required this.created,
    required List<ChatChoice> choices,
    required this.usage,
    this.requestId,
    required Map<String, Object?> raw,
  })  : choices = List.unmodifiable(choices),
        raw = Map.unmodifiable(raw);

  /// The exact fields of the pinned completion schema.
  static const wireFields = {
    'id',
    'object',
    'created',
    'model',
    'choices',
    'usage'
  };

  /// Completion id.
  final String id;

  /// Model that served the request.
  final String model;

  /// Creation time in Unix seconds.
  final int created;

  /// Completion choices.
  final List<ChatChoice> choices;

  /// Token usage, if supplied.
  final TokenUsage? usage;

  /// Clean request id from the response header, if available.
  final String? requestId;

  /// Original response fields, excluding unapproved usage fields.
  final Map<String, Object?> raw;

  /// The first choice's reply text, or an empty string.
  String get text => choices.isEmpty ? '' : choices.first.message.content ?? '';

  /// Reads a completion, rejecting missing or mistyped required fields.
  static ChatCompletion? fromJson(Object? value, {String? requestId}) {
    // [1] Check the envelope fields required by the pinned public schema.
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['object'] != 'chat.completion' ||
        value['created'] is! int ||
        (value['created'] as int) < 0 ||
        value['model'] is! String ||
        value['choices'] is! List ||
        value['usage'] is! Map<String, dynamic>) {
      return null;
    }
    // [2] Parse each choice and the limited usage record.
    final choices = <ChatChoice>[];
    for (final item in value['choices'] as List) {
      final choice = ChatChoice.fromJson(item);
      if (choice == null) return null;
      choices.add(choice);
    }
    if (choices.isEmpty || choices.length > 1) return null;
    final usage = TokenUsage.fromJson(value['usage']);
    if (usage == null) return null;
    // [3] Retain the response while limiting exposed usage fields.
    final raw = withoutPrices(value) as Map<String, Object?>;
    raw['usage'] = usage.toJson();
    return ChatCompletion(
      id: value['id'] as String,
      model: value['model'] as String,
      created: value['created'] as int,
      choices: choices,
      usage: usage,
      requestId: requestId,
      raw: raw,
    );
  }

  /// Writes this completion with usage limited to the three token counts.
  Map<String, Object?> toJson() => {
        ...raw,
        'usage': usage?.toJson(),
      };
}

/// One model in the public catalogue.
final class ModelInfo {
  /// Creates a model record.
  const ModelInfo({required this.id, required this.ownedBy});

  /// The exact fields of the pinned model-object schema.
  static const wireFields = {'id', 'object', 'owned_by'};

  /// Model id.
  final String id;

  /// Provider or Meridian owner.
  final String ownedBy;

  /// Reads a model record.
  static ModelInfo? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['object'] != 'model' ||
        value['owned_by'] is! String) {
      return null;
    }
    return ModelInfo(
        id: value['id'] as String, ownedBy: value['owned_by'] as String);
  }

  /// Writes this model record.
  Map<String, Object?> toJson() => {
        'id': id,
        'object': 'model',
        'owned_by': ownedBy,
      };
}

/// The public model catalogue.
final class ModelList {
  /// Creates a model list.
  ModelList({required List<ModelInfo> data}) : data = List.unmodifiable(data);

  /// The exact fields of the pinned list schema.
  static const wireFields = {'object', 'data'};

  /// Models returned by the engine.
  final List<ModelInfo> data;

  /// Reads a model list, rejecting invalid elements.
  static ModelList? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['object'] != 'list' ||
        value['data'] is! List) {
      return null;
    }
    final models = <ModelInfo>[];
    for (final item in value['data'] as List) {
      final model = ModelInfo.fromJson(item);
      if (model == null) return null;
      models.add(model);
    }
    return ModelList(data: models);
  }

  /// Writes this model list.
  Map<String, Object?> toJson() => {
        'object': 'list',
        'data': data.map((model) => model.toJson()).toList(),
      };
}
