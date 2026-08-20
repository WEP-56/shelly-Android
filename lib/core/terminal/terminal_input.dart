enum TerminalExtraKey {
  escape('escape', 'ESC'),
  control('control', 'CTRL'),
  alt('alt', 'ALT'),
  tab('tab', 'TAB'),
  minus('minus', '-'),
  slash('slash', '/'),
  pipe('pipe', '|'),
  tilde('tilde', '~'),
  home('home', 'HOME'),
  arrowUp('arrowUp', '↑'),
  end('end', 'END'),
  pageUp('pageUp', 'PGUP'),
  arrowLeft('arrowLeft', '←'),
  arrowDown('arrowDown', '↓'),
  arrowRight('arrowRight', '→'),
  pageDown('pageDown', 'PGDN');

  const TerminalExtraKey(this.id, this.label);

  final String id;
  final String label;

  bool get isModifier =>
      this == TerminalExtraKey.control || this == TerminalExtraKey.alt;

  bool get isRepeatable => switch (this) {
    TerminalExtraKey.home ||
    TerminalExtraKey.arrowUp ||
    TerminalExtraKey.end ||
    TerminalExtraKey.pageUp ||
    TerminalExtraKey.arrowLeft ||
    TerminalExtraKey.arrowDown ||
    TerminalExtraKey.arrowRight ||
    TerminalExtraKey.pageDown => true,
    _ => false,
  };
}

const defaultTerminalExtraKeys = <TerminalExtraKey>[
  TerminalExtraKey.escape,
  TerminalExtraKey.control,
  TerminalExtraKey.alt,
  TerminalExtraKey.tab,
  TerminalExtraKey.minus,
  TerminalExtraKey.slash,
  TerminalExtraKey.pipe,
  TerminalExtraKey.tilde,
  TerminalExtraKey.home,
  TerminalExtraKey.arrowUp,
  TerminalExtraKey.end,
  TerminalExtraKey.pageUp,
  TerminalExtraKey.arrowLeft,
  TerminalExtraKey.arrowDown,
  TerminalExtraKey.arrowRight,
  TerminalExtraKey.pageDown,
];

List<TerminalExtraKey> parseTerminalExtraKeyOrder(Object? value) {
  if (value is! List) return defaultTerminalExtraKeys;
  final byId = {for (final key in TerminalExtraKey.values) key.id: key};
  final parsed = <TerminalExtraKey>[];
  for (final item in value) {
    if (item is! String) continue;
    final key = byId[item];
    if (key != null && !parsed.contains(key)) parsed.add(key);
  }
  if (parsed.length != TerminalExtraKey.values.length) {
    return defaultTerminalExtraKeys;
  }
  return List.unmodifiable(parsed);
}
