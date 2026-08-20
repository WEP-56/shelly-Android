import 'dart:convert';

/// Result of bounding a tool's textual output.
class BoundedToolText {
  const BoundedToolText({
    required this.text,
    required this.truncated,
    required this.totalLines,
    required this.totalBytes,
  });

  /// Text that is safe to hand to the model.
  final String text;

  final bool truncated;

  /// Line and byte counts of the untruncated source, reported to the model so it
  /// knows how much it is not seeing.
  final int totalLines;
  final int totalBytes;

  /// Short Chinese notice appended to a tool result when content was dropped.
  String? get notice {
    if (!truncated) return null;
    final kilobytes = (totalBytes / 1024).toStringAsFixed(1);
    return '[输出已截断：原始共 $totalLines 行 / $kilobytes KB]';
  }

  /// The bounded text with the truncation notice attached.
  String get annotated {
    final tail = notice;
    if (tail == null) return text;
    return text.isEmpty ? tail : '$text\n$tail';
  }
}

/// Bounds tool output by lines and bytes.
///
/// Limits mirror what coding agents use in practice: a few thousand lines and a
/// few tens of kilobytes. Whole lines are dropped rather than cut, so the model
/// never has to reason about a half-written record. The only exception is a
/// single line that is itself larger than the byte budget.
abstract final class ToolOutput {
  static const maxLines = 2000;
  static const maxBytes = 50 * 1024;

  static final _ansi = RegExp(
    // CSI / OSC / single-character escapes emitted by interactive shells.
    r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[\[\(][0-9;?]*[ -/]*[@-~]|\x1B[@-Z\\-_]',
  );
  static final _controls = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

  static BoundedToolText limit(
    String source, {
    int lineLimit = maxLines,
    int byteLimit = maxBytes,
    bool keepTail = false,
  }) {
    final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final totalLines = lines.length;
    final totalBytes = utf8.encode(normalized).length;
    if (totalLines == 0) {
      return BoundedToolText(
        text: '',
        truncated: false,
        totalLines: 0,
        totalBytes: totalBytes,
      );
    }

    var truncated = false;
    var kept = lines;
    if (totalLines > lineLimit) {
      kept = keepTail
          ? lines.sublist(totalLines - lineLimit)
          : lines.sublist(0, lineLimit);
      truncated = true;
    }

    final selected = <String>[];
    var bytes = 0;
    for (final line in keepTail ? kept.reversed : kept) {
      final size = utf8.encode(line).length + 1;
      if (bytes + size > byteLimit) {
        truncated = true;
        if (selected.isEmpty) selected.add(_cutRunes(line, byteLimit));
        break;
      }
      bytes += size;
      selected.add(line);
    }

    final body = (keepTail ? selected.reversed : selected).join('\n');
    return BoundedToolText(
      text: body,
      truncated: truncated,
      totalLines: totalLines,
      totalBytes: totalBytes,
    );
  }

  /// Removes escape sequences and stray control characters from terminal text so
  /// the model reads content instead of cursor movement.
  static String sanitizeTerminal(String source) {
    return source
        .replaceAll('\r\n', '\n')
        .replaceAll(_ansi, '')
        .replaceAll('\r', '\n')
        .replaceAll(_controls, '');
  }

  /// Trims trailing blank lines without touching interior spacing.
  static String trimTrailingBlankLines(String source) {
    final lines = source.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  static String _cutRunes(String line, int byteLimit) {
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > byteLimit) break;
      bytes += size;
      buffer.write(char);
    }
    return buffer.toString();
  }
}
