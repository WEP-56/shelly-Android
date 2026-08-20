import '../core/terminal/terminal_input.dart';

enum ThemePreference { light, dark, system }

enum HostAuthType { password, privateKey }

class HostProfile {
  const HostProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.credentialRef,
    required this.createdAt,
    required this.updatedAt,
    this.lastPath,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final HostAuthType authType;
  final String? credentialRef;
  final String? lastPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get user => username;

  HostProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    HostAuthType? authType,
    String? credentialRef,
    String? lastPath,
    DateTime? updatedAt,
  }) {
    return HostProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      credentialRef: credentialRef ?? this.credentialRef,
      lastPath: lastPath ?? this.lastPath,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class HostDraft {
  const HostDraft({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    this.secret,
  });

  final String name;
  final String host;
  final int port;
  final String username;
  final HostAuthType authType;
  final String? secret;
}

class HostSaveRequest {
  const HostSaveRequest({required this.draft, this.existing});

  final HostDraft draft;
  final HostProfile? existing;
}

class AppSettings {
  const AppSettings({
    this.fontSize = 12.5,
    this.cursorBlink = true,
    this.keepAlive = true,
    this.autoReconnect = true,
    this.compression = true,
    this.sound = false,
    this.biometric = false,
    this.haptics = true,
    this.extraKeys = defaultTerminalExtraKeys,
  });

  final double fontSize;
  final bool cursorBlink;
  final bool keepAlive;
  final bool autoReconnect;
  final bool compression;
  final bool sound;
  final bool biometric;
  final bool haptics;
  final List<TerminalExtraKey> extraKeys;

  AppSettings copyWith({
    double? fontSize,
    bool? cursorBlink,
    bool? keepAlive,
    bool? autoReconnect,
    bool? compression,
    bool? sound,
    bool? biometric,
    bool? haptics,
    List<TerminalExtraKey>? extraKeys,
  }) {
    return AppSettings(
      fontSize: fontSize ?? this.fontSize,
      cursorBlink: cursorBlink ?? this.cursorBlink,
      keepAlive: keepAlive ?? this.keepAlive,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      compression: compression ?? this.compression,
      sound: sound ?? this.sound,
      biometric: biometric ?? this.biometric,
      haptics: haptics ?? this.haptics,
      extraKeys: extraKeys ?? this.extraKeys,
    );
  }

  Map<String, Object> toJson() => {
    'fontSize': fontSize,
    'cursorBlink': cursorBlink,
    'keepAlive': keepAlive,
    'autoReconnect': autoReconnect,
    'compression': compression,
    'sound': sound,
    'biometric': biometric,
    'haptics': haptics,
    'extraKeys': [for (final key in extraKeys) key.id],
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    return AppSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 12.5,
      cursorBlink: json['cursorBlink'] as bool? ?? true,
      keepAlive: json['keepAlive'] as bool? ?? true,
      autoReconnect: json['autoReconnect'] as bool? ?? true,
      compression: json['compression'] as bool? ?? true,
      sound: json['sound'] as bool? ?? false,
      biometric: json['biometric'] as bool? ?? false,
      haptics: json['haptics'] as bool? ?? true,
      extraKeys: parseTerminalExtraKeyOrder(json['extraKeys']),
    );
  }
}
