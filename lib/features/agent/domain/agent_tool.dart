import 'agent_failure.dart';

/// Minimal JSON-Schema field descriptors.
///
/// Only the shapes the product's tools actually need are modeled. Anything the
/// model sends that does not match is rejected with a message the model can act
/// on, instead of being coerced into a guess.
sealed class ToolField {
  const ToolField({required this.description, this.required = true});

  final String description;
  final bool required;

  Map<String, Object?> toJsonSchema();

  /// Returns the validated value, or throws [AgentToolArgumentException].
  Object? validate(String name, Object? value);
}

class StringField extends ToolField {
  const StringField({
    required super.description,
    super.required,
    this.maxLength,
    this.allowEmpty = false,
  });

  final int? maxLength;
  final bool allowEmpty;

  @override
  Map<String, Object?> toJsonSchema() => {
    'type': 'string',
    'description': description,
    if (maxLength != null) 'maxLength': maxLength,
  };

  @override
  String validate(String name, Object? value) {
    if (value is! String) {
      throw AgentToolArgumentException('参数 "$name" 必须是字符串。');
    }
    if (!allowEmpty && value.trim().isEmpty) {
      throw AgentToolArgumentException('参数 "$name" 不能为空。');
    }
    final limit = maxLength;
    if (limit != null && value.length > limit) {
      throw AgentToolArgumentException('参数 "$name" 超过 $limit 个字符。');
    }
    return value;
  }
}

class IntField extends ToolField {
  const IntField({
    required super.description,
    super.required,
    this.minimum,
    this.maximum,
  });

  final int? minimum;
  final int? maximum;

  @override
  Map<String, Object?> toJsonSchema() => {
    'type': 'integer',
    'description': description,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
  };

  @override
  int validate(String name, Object? value) {
    final parsed = switch (value) {
      final int number => number,
      final double number when number == number.roundToDouble() =>
        number.toInt(),
      final String text => int.tryParse(text.trim()),
      _ => null,
    };
    if (parsed == null) {
      throw AgentToolArgumentException('参数 "$name" 必须是整数。');
    }
    final low = minimum;
    final high = maximum;
    if (low != null && parsed < low) {
      throw AgentToolArgumentException('参数 "$name" 不能小于 $low。');
    }
    if (high != null && parsed > high) {
      throw AgentToolArgumentException('参数 "$name" 不能大于 $high。');
    }
    return parsed;
  }
}

class BoolField extends ToolField {
  const BoolField({required super.description, super.required});

  @override
  Map<String, Object?> toJsonSchema() => {
    'type': 'boolean',
    'description': description,
  };

  @override
  bool validate(String name, Object? value) {
    if (value is bool) return value;
    if (value == 'true') return true;
    if (value == 'false') return false;
    throw AgentToolArgumentException('参数 "$name" 必须是布尔值。');
  }
}

class StringListField extends ToolField {
  const StringListField({
    required super.description,
    super.required,
    this.maxItems,
    this.itemMaxLength,
  });

  final int? maxItems;
  final int? itemMaxLength;

  @override
  Map<String, Object?> toJsonSchema() => {
    'type': 'array',
    'description': description,
    'items': {
      'type': 'string',
      if (itemMaxLength != null) 'maxLength': itemMaxLength,
    },
    if (maxItems != null) 'maxItems': maxItems,
  };

  @override
  List<String> validate(String name, Object? value) {
    if (value is! List) {
      throw AgentToolArgumentException('参数 "$name" 必须是字符串数组。');
    }
    if (value.isEmpty) {
      throw AgentToolArgumentException('参数 "$name" 至少需要一项。');
    }
    final limit = maxItems;
    if (limit != null && value.length > limit) {
      throw AgentToolArgumentException('参数 "$name" 最多 $limit 项。');
    }
    final items = <String>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) {
        throw AgentToolArgumentException('参数 "$name" 的每一项都必须是非空字符串。');
      }
      final itemLimit = itemMaxLength;
      if (itemLimit != null && item.length > itemLimit) {
        throw AgentToolArgumentException('参数 "$name" 的单项超过 $itemLimit 个字符。');
      }
      items.add(item);
    }
    return items;
  }
}

class ToolSchema {
  const ToolSchema(this.fields);

  static const empty = ToolSchema(<String, ToolField>{});

  final Map<String, ToolField> fields;

  Map<String, Object?> toJsonSchema() {
    final required = [
      for (final entry in fields.entries)
        if (entry.value.required) entry.key,
    ];
    return {
      'type': 'object',
      'properties': {
        for (final entry in fields.entries)
          entry.key: entry.value.toJsonSchema(),
      },
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };
  }

  /// Validates raw model arguments. Unknown keys are dropped rather than
  /// rejected: models routinely add stray fields, and the tool only reads what
  /// the schema declares.
  ToolArguments validate(Map<String, Object?> raw) {
    final validated = <String, Object?>{};
    for (final entry in fields.entries) {
      final value = raw[entry.key];
      if (value == null) {
        if (entry.value.required) {
          throw AgentToolArgumentException('缺少必填参数 "${entry.key}"。');
        }
        continue;
      }
      validated[entry.key] = entry.value.validate(entry.key, value);
    }
    return ToolArguments(validated);
  }
}

class ToolArguments {
  const ToolArguments(this._values);

  final Map<String, Object?> _values;

  bool has(String name) => _values.containsKey(name);

  String string(String name) => _values[name]! as String;

  String? optionalString(String name) => _values[name] as String?;

  int integer(String name, {required int fallback}) =>
      _values[name] as int? ?? fallback;

  bool boolean(String name, {required bool fallback}) =>
      _values[name] as bool? ?? fallback;

  List<String> stringList(String name) => _values[name]! as List<String>;
}

class AgentToolResult {
  const AgentToolResult({
    required this.text,
    this.isError = false,
    this.details,
  });

  /// Text handed back to the model as the tool result.
  final String text;

  final bool isError;

  /// UI-only structured payload. Never serialized into a provider request.
  final Map<String, Object?>? details;
}

/// Cooperative cancellation shared by the loop, the provider stream and every
/// running tool.
class AgentCancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (!_cancelled) return;
    throw const AgentFailure(
      stage: AgentFailureStage.cancelled,
      message: '已取消。',
    );
  }
}

enum AgentToolKind {
  /// Side-effect free. May run without user interaction.
  read,

  /// Produces a command-approval request. Never writes without approval.
  write,
}

abstract interface class AgentTool {
  String get name;

  /// Short label shown in the transcript.
  String get label;

  String get description;

  ToolSchema get schema;

  AgentToolKind get kind;

  /// Executes the tool. Throws [AgentToolException] for expected failures; the
  /// loop turns those into an error tool result and keeps the loop alive.
  Future<AgentToolResult> execute(
    String toolCallId,
    ToolArguments arguments,
    AgentCancellationToken cancellation,
  );
}
