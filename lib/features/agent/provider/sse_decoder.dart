import 'dart:async';

/// One decoded `text/event-stream` event.
class SseEvent {
  const SseEvent({required this.event, required this.data});

  /// Value of the `event:` field, or null when the server only sent `data:`.
  final String? event;

  /// Concatenated `data:` lines joined with newlines.
  final String data;

  bool get isEmpty => event == null && data.isEmpty;
}

/// Field-based SSE decoder.
///
/// Splits on CR, LF and CRLF, treats a blank line as the event boundary, skips
/// `:` comment lines and strips one optional leading space from field values —
/// the same framing rules the W3C spec defines. Parsing the fields instead of
/// slicing the raw text keeps `data:` payloads that themselves contain `event:`
/// or blank-looking JSON intact.
class SseDecoder extends StreamTransformerBase<String, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<String> stream) {
    return Stream<SseEvent>.eventTransformed(
      stream,
      (sink) => _SseDecoderSink(sink),
    );
  }
}

class _SseDecoderSink implements EventSink<String> {
  _SseDecoderSink(this._sink);

  final EventSink<SseEvent> _sink;
  final StringBuffer _buffer = StringBuffer();
  String? _event;
  final List<String> _data = [];

  @override
  void add(String chunk) {
    _buffer.write(chunk);
    var pending = _buffer.toString();
    _buffer.clear();
    while (true) {
      final consumed = _consumeLine(pending);
      if (consumed == null) break;
      pending = consumed.rest;
      _decodeLine(consumed.line);
    }
    _buffer.write(pending);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _sink.addError(error, stackTrace);
  }

  @override
  void close() {
    final tail = _buffer.toString();
    _buffer.clear();
    if (tail.isNotEmpty) _decodeLine(tail);
    _flush();
    _sink.close();
  }

  void _decodeLine(String line) {
    if (line.isEmpty) {
      _flush();
      return;
    }
    if (line.startsWith(':')) return;
    final delimiter = line.indexOf(':');
    final field = delimiter == -1 ? line : line.substring(0, delimiter);
    var value = delimiter == -1 ? '' : line.substring(delimiter + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _event = value;
    } else if (field == 'data') {
      _data.add(value);
    }
  }

  void _flush() {
    if (_event == null && _data.isEmpty) return;
    final event = SseEvent(event: _event, data: _data.join('\n'));
    _event = null;
    _data.clear();
    if (!event.isEmpty) _sink.add(event);
  }

  _ConsumedLine? _consumeLine(String text) {
    final breakIndex = _nextLineBreak(text);
    if (breakIndex == -1) return null;
    var next = breakIndex + 1;
    if (text.codeUnitAt(breakIndex) == 13 &&
        next < text.length &&
        text.codeUnitAt(next) == 10) {
      next += 1;
    }
    return _ConsumedLine(text.substring(0, breakIndex), text.substring(next));
  }

  int _nextLineBreak(String text) {
    final carriageReturn = text.indexOf('\r');
    final newline = text.indexOf('\n');
    if (carriageReturn == -1) return newline;
    if (newline == -1) return carriageReturn;
    return carriageReturn < newline ? carriageReturn : newline;
  }
}

class _ConsumedLine {
  const _ConsumedLine(this.line, this.rest);

  final String line;
  final String rest;
}
