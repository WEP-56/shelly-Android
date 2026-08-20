import 'dart:convert';

/// JSON helpers for provider payloads.
///
/// Tool-call arguments arrive as a token stream, so partial JSON has to be
/// tolerated while streaming and finalized once the block closes. Nothing here
/// invents values: an unparsable partial yields an empty map and the loop's
/// schema validation reports the missing arguments to the model.
abstract final class AgentJson {
  static Map<String, Object?> decodeObject(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw FormatException('Expected a JSON object', source);
    }
    return Map<String, Object?>.from(value);
  }

  /// Parses complete tool-call arguments. Falls back to the streaming parser so a
  /// provider that drops the closing brace still produces the fields it did send.
  static Map<String, Object?> decodeArguments(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return const {};
    try {
      return decodeObject(trimmed);
    } on FormatException {
      return decodePartialArguments(trimmed);
    }
  }

  /// Parses possibly-truncated JSON by closing open strings, arrays and objects.
  /// Only used for streaming previews and as a salvage path.
  static Map<String, Object?> decodePartialArguments(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return const {};
    final repaired = _closeOpenStructures(trimmed);
    if (repaired == null) return const {};
    try {
      final value = jsonDecode(repaired);
      return value is Map ? Map<String, Object?>.from(value) : const {};
    } on FormatException {
      return const {};
    }
  }

  /// Appends the closing tokens a truncated JSON document needs. Returns null
  /// when the text cannot be repaired into a value.
  static String? _closeOpenStructures(String source) {
    final stack = <String>[];
    var inString = false;
    var escaped = false;
    var lastMeaningful = -1;

    for (var index = 0; index < source.length; index++) {
      final char = source[index];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
          lastMeaningful = index;
        }
        continue;
      }
      switch (char) {
        case '"':
          inString = true;
        case '{':
          stack.add('}');
        case '[':
          stack.add(']');
        case '}':
        case ']':
          if (stack.isEmpty) return null;
          stack.removeLast();
          lastMeaningful = index;
        case ' ':
        case '\t':
        case '\n':
        case '\r':
          break;
        default:
          lastMeaningful = index;
      }
    }

    var body = source;
    if (inString) {
      // An open string literal cannot be completed safely when it is a key, so
      // drop the trailing fragment back to the last complete token.
      if (escaped) body = body.substring(0, body.length - 1);
      body = '$body"';
      lastMeaningful = body.length - 1;
    }
    if (lastMeaningful >= 0 && lastMeaningful < body.length - 1) {
      body = body.substring(0, lastMeaningful + 1);
    }
    body = body.trimRight();
    while (body.endsWith(',') || body.endsWith(':')) {
      body = body.substring(0, body.length - 1).trimRight();
    }
    if (body.isEmpty) return null;
    return body + stack.reversed.join();
  }

  /// Reads a provider error body without leaking a huge payload into a message.
  static String? describeErrorBody(String body, {int maxChars = 600}) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      final value = jsonDecode(trimmed);
      if (value is Map) {
        final error = value['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String && message.trim().isNotEmpty) {
            return _cap(message.trim(), maxChars);
          }
          final type = error['type'];
          if (type is String && type.trim().isNotEmpty) {
            return _cap(type.trim(), maxChars);
          }
        }
        if (error is String && error.trim().isNotEmpty) {
          return _cap(error.trim(), maxChars);
        }
        final message = value['message'];
        if (message is String && message.trim().isNotEmpty) {
          return _cap(message.trim(), maxChars);
        }
      }
    } on FormatException {
      // Non-JSON bodies are surfaced verbatim below.
    }
    return _cap(trimmed, maxChars);
  }

  static String _cap(String value, int maxChars) {
    if (value.length <= maxChars) return value;
    return '${value.substring(0, maxChars)}…';
  }
}
